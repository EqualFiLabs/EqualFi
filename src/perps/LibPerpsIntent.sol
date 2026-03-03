// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {
    Perps_AccountNotFound,
    Perps_BadSignature,
    Perps_IntentCanceled,
    Perps_IntentExpired,
    Perps_InvalidIntent,
    Perps_NonceInvalidated,
    Perps_NonceMismatch,
    Perps_Unauthorized
} from "./PerpsErrors.sol";

interface IPerpsPositionNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// @notice EIP-712 intent hashing, validation, replay protection, and cancellation helpers.
library LibPerpsIntent {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");
    bytes32 internal constant PERPS_INTENT_TYPEHASH = keccak256(
        "PerpsIntent(bytes32 marketId,bytes32 accountId,uint8 action,bool isLong,uint256 sizeDeltaUsdX18,int256 collateralDelta,uint256 limitPriceX18,uint256 maxSlippageBps,uint256 maxExecutorFee,uint64 nonce,uint64 deadline)"
    );
    bytes32 internal constant EIP712_NAME_HASH = keccak256("EqualisPerps");
    bytes32 internal constant EIP712_VERSION_HASH = keccak256("1");
    bytes32 internal constant EIP712_DOMAIN_SALT = keccak256("equalis.perps.gmxstyle.module.v1");

    event PerpsIntentCanceled(bytes32 indexed accountId, bytes32 indexed intentHash, address caller);
    event PerpsNonceInvalidated(bytes32 indexed accountId, uint64 previousMinNonce, uint64 newMinNonce, address caller);

    function domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, EIP712_VERSION_HASH, block.chainid, address(this), EIP712_DOMAIN_SALT
            )
        );
    }

    function hashIntent(LibPerpsStorage.PerpsIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PERPS_INTENT_TYPEHASH,
                intent.marketId,
                intent.accountId,
                intent.action,
                intent.isLong,
                intent.sizeDeltaUsdX18,
                intent.collateralDelta,
                intent.limitPriceX18,
                intent.maxSlippageBps,
                intent.maxExecutorFee,
                intent.nonce,
                intent.deadline
            )
        );
    }

    function intentDigest(LibPerpsStorage.PerpsIntent memory intent) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(domainSeparator(), hashIntent(intent));
    }

    function isIntentCanceled(bytes32 intentHash) internal view returns (bool) {
        return LibPerpsStorage.s().canceledIntents[intentHash];
    }

    function validateIntentAndSignature(
        LibPerpsStorage.PerpsIntent memory intent,
        address signer,
        bytes memory signature
    ) internal view returns (bytes32 intentHash) {
        intentHash = hashIntent(intent);
        validateIntentState(intent, intentHash);

        if (signer == address(0)) {
            revert Perps_BadSignature();
        }
        requireSignerAuthority(intent.accountId, signer);

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator(), intentHash);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) {
            revert Perps_BadSignature();
        }
    }

    function validateIntentState(LibPerpsStorage.PerpsIntent memory intent, bytes32 intentHash) internal view {
        if (intent.marketId == bytes32(0) || intent.accountId == bytes32(0)) {
            revert Perps_InvalidIntent();
        }

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsAccount storage account = ps.accounts[intent.accountId];
        if (!account.exists) {
            revert Perps_AccountNotFound(intent.accountId);
        }

        uint64 nowTs = uint64(block.timestamp);
        if (intent.deadline < nowTs) {
            revert Perps_IntentExpired(intent.deadline, nowTs);
        }
        if (ps.canceledIntents[intentHash]) {
            revert Perps_IntentCanceled(intentHash);
        }

        uint64 minNonce = ps.minValidNonce[intent.accountId];
        if (intent.nonce < minNonce) {
            revert Perps_NonceInvalidated(minNonce, intent.nonce);
        }
        if (intent.nonce != account.nonce) {
            revert Perps_NonceMismatch(account.nonce, intent.nonce);
        }
    }

    function consumeIntentNonce(bytes32 accountId, uint64 nonce) internal {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsAccount storage account = ps.accounts[accountId];
        if (!account.exists) {
            revert Perps_AccountNotFound(accountId);
        }

        uint64 minNonce = ps.minValidNonce[accountId];
        if (nonce < minNonce) {
            revert Perps_NonceInvalidated(minNonce, nonce);
        }
        if (nonce != account.nonce) {
            revert Perps_NonceMismatch(account.nonce, nonce);
        }
        if (nonce == type(uint64).max) {
            revert Perps_InvalidIntent();
        }
        account.nonce = nonce + 1;
    }

    function requireDirectCallAuthority(bytes32 accountId) internal view {
        LibPerpsStorage.PerpsAccount storage account = _loadAccount(accountId);
        if (!_isAuthorizedController(account, msg.sender)) {
            revert Perps_Unauthorized(accountId, msg.sender);
        }
    }

    function requireSignerAuthority(bytes32 accountId, address signer) internal view {
        LibPerpsStorage.PerpsAccount storage account = _loadAccount(accountId);
        if (!_isAuthorizedController(account, signer)) {
            revert Perps_Unauthorized(accountId, signer);
        }
    }

    function cancelIntent(bytes32 accountId, bytes32 intentHash) internal {
        if (intentHash == bytes32(0)) {
            revert Perps_InvalidIntent();
        }

        LibPerpsStorage.PerpsAccount storage account = _loadAccount(accountId);
        if (!_isAuthorizedController(account, msg.sender)) {
            revert Perps_Unauthorized(accountId, msg.sender);
        }

        LibPerpsStorage.s().canceledIntents[intentHash] = true;
        emit PerpsIntentCanceled(accountId, intentHash, msg.sender);
    }

    function invalidateNoncesUpTo(bytes32 accountId, uint64 nonceUpperBound) internal {
        if (nonceUpperBound == 0) {
            revert Perps_InvalidIntent();
        }

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsAccount storage account = ps.accounts[accountId];
        if (!account.exists) {
            revert Perps_AccountNotFound(accountId);
        }
        if (!_isAuthorizedController(account, msg.sender)) {
            revert Perps_Unauthorized(accountId, msg.sender);
        }

        uint64 previousMinNonce = ps.minValidNonce[accountId];
        if (nonceUpperBound <= previousMinNonce) {
            revert Perps_NonceInvalidated(previousMinNonce, nonceUpperBound);
        }

        ps.minValidNonce[accountId] = nonceUpperBound;
        if (account.nonce < nonceUpperBound) {
            account.nonce = nonceUpperBound;
        }

        emit PerpsNonceInvalidated(accountId, previousMinNonce, nonceUpperBound, msg.sender);
    }

    function _loadAccount(bytes32 accountId) private view returns (LibPerpsStorage.PerpsAccount storage account) {
        account = LibPerpsStorage.s().accounts[accountId];
        if (!account.exists) {
            revert Perps_AccountNotFound(accountId);
        }
    }

    function _isAuthorizedController(LibPerpsStorage.PerpsAccount storage account, address actor)
        private
        view
        returns (bool)
    {
        address nftAddress = LibPositionNFT.s().positionNFTContract;
        if (nftAddress == address(0)) {
            return false;
        }

        IPerpsPositionNFT nft = IPerpsPositionNFT(nftAddress);
        address owner = nft.ownerOf(account.positionTokenId);
        if (actor == owner || nft.getApproved(account.positionTokenId) == actor || nft.isApprovedForAll(owner, actor)) {
            return true;
        }

        return _isCanonicalTba(account.positionTokenId, actor);
    }

    function _isCanonicalTba(uint256 positionTokenId, address actor) private view returns (bool) {
        LibPositionAgentStorage.AgentStorage storage ads = LibPositionAgentStorage.s();
        if (ads.erc6551Registry == address(0) || ads.erc6551Implementation == address(0)) {
            return false;
        }
        if (ads.erc6551Registry.code.length == 0) {
            return false;
        }

        address nftAddress = LibPositionNFT.s().positionNFTContract;
        if (nftAddress == address(0)) {
            return false;
        }

        try IERC6551Registry(ads.erc6551Registry).account(
            ads.erc6551Implementation, ads.tbaSalt, block.chainid, nftAddress, positionTokenId
        ) returns (address canonicalTba) {
            return actor == canonicalTba && actor.code.length > 0;
        } catch {
            return false;
        }
    }
}

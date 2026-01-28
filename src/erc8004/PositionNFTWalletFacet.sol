// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibERC8004Storage} from "../libraries/LibERC8004Storage.sol";
import {
    ERC8004_Unauthorized,
    ERC8004_DeadlineExpired,
    ERC8004_InvalidSignature,
    ERC8004_InvalidSignatureLength,
    ERC8004_NonceAlreadyUsed,
    ERC8004_ERC1271ValidationFailed
} from "../libraries/ERC8004Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";

/// @title PositionNFTWalletFacet
/// @notice ERC-8004 agent wallet verification for Position NFTs
contract PositionNFTWalletFacet {
    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,uint256 nonce,uint256 deadline)");

    bytes4 private constant ERC1271_MAGICVALUE = 0x1626ba7e;
    bytes32 private constant AGENT_WALLET_KEY_HASH = keccak256(bytes("agentWallet"));
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        address registry = _positionNFTAddress();
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PositionNFT")),
                keccak256(bytes("1")),
                block.chainid,
                registry
            )
        );
    }

    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external {
        LibERC8004Storage.requireAuthorized(agentId);
        if (deadline < block.timestamp) {
            revert ERC8004_DeadlineExpired(deadline, block.timestamp);
        }
        if (newWallet.code.length == 0 && signature.length != 65) {
            revert ERC8004_InvalidSignatureLength(signature.length);
        }

        LibERC8004Storage.ERC8004Storage storage ds = LibERC8004Storage.s();
        uint256 nonce = ds.agentNonces[agentId];

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, nonce, deadline))
        );

        if (!_isValidSignature(newWallet, digest, signature)) {
            if (nonce > 0) {
                bytes32 prevDigest = _hashTypedDataV4(
                    keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, nonce - 1, deadline))
                );
                if (_isValidSignature(newWallet, prevDigest, signature)) {
                    revert ERC8004_NonceAlreadyUsed(agentId, nonce - 1);
                }
            }
            revert ERC8004_InvalidSignature();
        }

        ds.metadata[agentId][AGENT_WALLET_KEY_HASH] = abi.encode(newWallet);
        ds.agentNonces[agentId] = nonce + 1;

        emit MetadataSet(agentId, "agentWallet", "agentWallet", abi.encode(newWallet));
    }

    function onAgentTransfer(uint256 agentId) external {
        address registry = _positionNFTAddress();
        if (msg.sender != registry) {
            revert ERC8004_Unauthorized(msg.sender, agentId);
        }

        LibERC8004Storage.ERC8004Storage storage ds = LibERC8004Storage.s();
        ds.metadata[agentId][AGENT_WALLET_KEY_HASH] = abi.encode(address(0));
        ds.agentNonces[agentId] = ds.agentNonces[agentId] + 1;

        emit MetadataSet(agentId, "agentWallet", "agentWallet", abi.encode(address(0)));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _isValidSignature(address wallet, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (wallet.code.length > 0) {
            (bool ok, bytes memory data) = wallet.staticcall(
                abi.encodeWithSignature("isValidSignature(bytes32,bytes)", digest, signature)
            );
            if (!ok || data.length < 4) {
                return false;
            }
            bytes4 result;
            assembly {
                result := mload(add(data, 32))
            }
            return result == ERC1271_MAGICVALUE;
        }

        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
        address recovered = ecrecover(digest, v, r, s);
        return recovered != address(0) && recovered == wallet;
    }

    function _splitSignature(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) {
            v += 27;
        }
    }

    function _positionNFTAddress() internal view returns (address) {
        address registry = LibPositionNFT.s().positionNFTContract;
        if (registry == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return registry;
    }

    function _requireAuthorized(uint256 agentId) internal view {
        LibERC8004Storage.requireAuthorized(agentId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPerpsIntent} from "../../src/perps/LibPerpsIntent.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {
    Perps_IntentExpired,
    Perps_BadSignature,
    Perps_NonceMismatch,
    Perps_NonceInvalidated,
    Perps_IntentCanceled,
    Perps_Unauthorized
} from "../../src/perps/PerpsErrors.sol";

contract MockPerpsPositionNFT {
    mapping(uint256 => address) internal _ownerByToken;
    mapping(uint256 => address) internal _approvedByToken;
    mapping(address => mapping(address => bool)) internal _operatorApproval;

    function setOwner(uint256 tokenId, address owner) external {
        _ownerByToken[tokenId] = owner;
    }

    function setApproved(uint256 tokenId, address approved) external {
        _approvedByToken[tokenId] = approved;
    }

    function setApprovedForAll(address owner, address operator, bool approved) external {
        _operatorApproval[owner][operator] = approved;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _ownerByToken[tokenId];
        require(owner != address(0), "token missing");
        return owner;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _approvedByToken[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApproval[owner][operator];
    }
}

contract Mock6551Registry is IERC6551Registry {
    mapping(bytes32 => address) internal _accountByKey;

    function setAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId,
        address account_
    ) external {
        _accountByKey[_key(implementation, salt, chainId, tokenContract, tokenId)] = account_;
    }

    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account_) {
        return _accountByKey[_key(implementation, salt, chainId, tokenContract, tokenId)];
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account_) {
        return _accountByKey[_key(implementation, salt, chainId, tokenContract, tokenId)];
    }

    function _key(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
    }
}

contract MockTbaAccount {}

contract Mock1271Signer is IERC1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    bytes32 public expectedDigest;
    bytes public expectedSignature;

    function setExpected(bytes32 digest, bytes calldata signature) external {
        expectedDigest = digest;
        expectedSignature = signature;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (digest == expectedDigest && keccak256(signature) == keccak256(expectedSignature)) {
            return MAGIC;
        }
        return bytes4(0xffffffff);
    }
}

contract PerpsIntentHarness {
    function setPositionNft(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setAgentConfig(address registry, address implementation, bytes32 salt) external {
        LibPositionAgentStorage.AgentStorage storage as_ = LibPositionAgentStorage.s();
        as_.erc6551Registry = registry;
        as_.erc6551Implementation = implementation;
        as_.tbaSalt = salt;
    }

    function seedAccount(bytes32 accountId, bytes32 positionKey, uint256 positionTokenId, uint64 nonce, bool exists)
        external
    {
        LibPerpsStorage.PerpsAccount storage account = LibPerpsStorage.s().accounts[accountId];
        account.accountId = accountId;
        account.positionKey = positionKey;
        account.positionTokenId = positionTokenId;
        account.nonce = nonce;
        account.exists = exists;
    }

    function setMinValidNonce(bytes32 accountId, uint64 newMinValidNonce) external {
        LibPerpsStorage.s().minValidNonce[accountId] = newMinValidNonce;
    }

    function minValidNonce(bytes32 accountId) external view returns (uint64) {
        return LibPerpsStorage.s().minValidNonce[accountId];
    }

    function accountNonce(bytes32 accountId) external view returns (uint64) {
        return LibPerpsStorage.s().accounts[accountId].nonce;
    }

    function domainSeparator() external view returns (bytes32) {
        return LibPerpsIntent.domainSeparator();
    }

    function hashIntent(LibPerpsStorage.PerpsIntent calldata intent) external pure returns (bytes32) {
        return LibPerpsIntent.hashIntent(intent);
    }

    function intentDigest(LibPerpsStorage.PerpsIntent calldata intent) external view returns (bytes32) {
        return LibPerpsIntent.intentDigest(intent);
    }

    function validateIntentAndSignature(
        LibPerpsStorage.PerpsIntent calldata intent,
        address signer,
        bytes calldata signature
    ) external view returns (bytes32 intentHash) {
        return LibPerpsIntent.validateIntentAndSignature(intent, signer, signature);
    }

    function validateIntentState(LibPerpsStorage.PerpsIntent calldata intent, bytes32 intentHash) external view {
        LibPerpsIntent.validateIntentState(intent, intentHash);
    }

    function consumeIntentNonce(bytes32 accountId, uint64 nonce) external {
        LibPerpsIntent.consumeIntentNonce(accountId, nonce);
    }

    function requireDirectCallAuthority(bytes32 accountId) external view {
        LibPerpsIntent.requireDirectCallAuthority(accountId);
    }

    function requireSignerAuthority(bytes32 accountId, address signer) external view {
        LibPerpsIntent.requireSignerAuthority(accountId, signer);
    }

    function cancelIntent(bytes32 accountId, bytes32 intentHash) external {
        LibPerpsIntent.cancelIntent(accountId, intentHash);
    }

    function invalidateNoncesUpTo(bytes32 accountId, uint64 nonceUpperBound) external {
        LibPerpsIntent.invalidateNoncesUpTo(accountId, nonceUpperBound);
    }

    function isIntentCanceled(bytes32 intentHash) external view returns (bool) {
        return LibPerpsIntent.isIntentCanceled(intentHash);
    }
}

contract PerpsIntentTest is Test {
    event PerpsIntentCanceled(bytes32 indexed accountId, bytes32 indexed intentHash, address caller);
    event PerpsNonceInvalidated(bytes32 indexed accountId, uint64 previousMinNonce, uint64 newMinNonce, address caller);

    PerpsIntentHarness internal h;
    MockPerpsPositionNFT internal nft;
    Mock6551Registry internal registry;
    MockTbaAccount internal tba;
    Mock1271Signer internal signer1271;

    uint256 internal ownerKey;
    uint256 internal otherKey;
    address internal owner;
    address internal other;
    address internal operator;

    bytes32 internal accountId;
    uint256 internal tokenId;
    bytes32 internal tbaSalt;

    function setUp() public {
        h = new PerpsIntentHarness();
        nft = new MockPerpsPositionNFT();
        registry = new Mock6551Registry();
        tba = new MockTbaAccount();
        signer1271 = new Mock1271Signer();

        ownerKey = 0xA11CE;
        otherKey = 0xB0B;
        owner = vm.addr(ownerKey);
        other = vm.addr(otherKey);
        operator = address(0xCAFE);

        accountId = keccak256("perps.intent.account");
        tokenId = 42;
        tbaSalt = keccak256("perps.intent.tba.salt");

        h.setPositionNft(address(nft));
        h.setAgentConfig(address(registry), address(0xABCD), tbaSalt);
        h.seedAccount(accountId, keccak256("position-key"), tokenId, 7, true);

        nft.setOwner(tokenId, owner);
        registry.setAccount(address(0xABCD), tbaSalt, block.chainid, address(nft), tokenId, address(tba));
    }

    function test_signatureValidation_acceptsValidOwnerSignature() public {
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, uint64(block.timestamp + 1 days));
        bytes32 digest = h.intentDigest(intent);
        bytes memory signature = _signDigest(ownerKey, digest);

        bytes32 intentHash = h.validateIntentAndSignature(intent, owner, signature);
        assertEq(intentHash, h.hashIntent(intent));
    }

    function test_signatureValidation_rejectsBadSignature() public {
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, uint64(block.timestamp + 1 days));
        bytes32 digest = h.intentDigest(intent);
        bytes memory signature = _signDigest(otherKey, digest);

        vm.expectRevert(abi.encodeWithSelector(Perps_BadSignature.selector));
        h.validateIntentAndSignature(intent, owner, signature);
    }

    function test_deadlineHandling_revertsWhenExpired() public {
        vm.warp(10_000);
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, 9_999);
        bytes32 intentHash = h.hashIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Perps_IntentExpired.selector, uint64(9_999), uint64(10_000)));
        h.validateIntentState(intent, intentHash);
    }

    function test_replayProtection_nonceConsumedThenRejectsReuse() public {
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, uint64(block.timestamp + 1 days));
        bytes memory signature = _signDigest(ownerKey, h.intentDigest(intent));

        h.validateIntentAndSignature(intent, owner, signature);
        h.consumeIntentNonce(accountId, 7);
        assertEq(h.accountNonce(accountId), 8);

        vm.expectRevert(abi.encodeWithSelector(Perps_NonceMismatch.selector, uint64(8), uint64(7)));
        h.validateIntentAndSignature(intent, owner, signature);
    }

    function test_cancelIntent_onChainBlocksExecution() public {
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, uint64(block.timestamp + 1 days));
        bytes32 intentHash = h.hashIntent(intent);

        vm.expectEmit(true, true, true, true);
        emit PerpsIntentCanceled(accountId, intentHash, owner);
        vm.prank(owner);
        h.cancelIntent(accountId, intentHash);

        assertTrue(h.isIntentCanceled(intentHash));

        bytes memory signature = _signDigest(ownerKey, h.intentDigest(intent));
        vm.expectRevert(abi.encodeWithSelector(Perps_IntentCanceled.selector, intentHash));
        h.validateIntentAndSignature(intent, owner, signature);
    }

    function test_bulkNonceInvalidation_advancesFloorAndPreventsOldNonce() public {
        vm.expectEmit(true, false, false, true);
        emit PerpsNonceInvalidated(accountId, 0, 15, owner);
        vm.prank(owner);
        h.invalidateNoncesUpTo(accountId, 15);

        assertEq(h.minValidNonce(accountId), 15);
        assertEq(h.accountNonce(accountId), 15);

        LibPerpsStorage.PerpsIntent memory oldIntent = _intent(14, uint64(block.timestamp + 1 days));
        bytes32 oldIntentHash = h.hashIntent(oldIntent);
        vm.expectRevert(abi.encodeWithSelector(Perps_NonceInvalidated.selector, uint64(15), uint64(14)));
        h.validateIntentState(oldIntent, oldIntentHash);
    }

    function test_directAuthorization_ownerApprovedOperatorAndTba() public {
        vm.prank(owner);
        h.requireDirectCallAuthority(accountId);

        nft.setApproved(tokenId, other);
        vm.prank(other);
        h.requireDirectCallAuthority(accountId);

        nft.setApprovedForAll(owner, operator, true);
        vm.prank(operator);
        h.requireDirectCallAuthority(accountId);

        vm.prank(address(tba));
        h.requireDirectCallAuthority(accountId);
    }

    function test_directAuthorization_revertsForUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(Perps_Unauthorized.selector, accountId, other));
        vm.prank(other);
        h.requireDirectCallAuthority(accountId);
    }

    function test_signatureValidation_acceptsAuthorizedErc1271Signer() public {
        LibPerpsStorage.PerpsIntent memory intent = _intent(7, uint64(block.timestamp + 1 days));
        bytes32 digest = h.intentDigest(intent);
        bytes memory signature = abi.encodePacked("valid-contract-signature");

        signer1271.setExpected(digest, signature);
        nft.setApproved(tokenId, address(signer1271));

        bytes32 intentHash = h.validateIntentAndSignature(intent, address(signer1271), signature);
        assertEq(intentHash, h.hashIntent(intent));
    }

    function _intent(uint64 nonce, uint64 deadline) internal view returns (LibPerpsStorage.PerpsIntent memory intent) {
        intent.marketId = keccak256("perps.intent.market");
        intent.accountId = accountId;
        intent.action = 1;
        intent.isLong = true;
        intent.sizeDeltaUsdX18 = 10_000e18;
        intent.collateralDelta = int256(1_000e6);
        intent.limitPriceX18 = 2_000e18;
        intent.maxSlippageBps = 100;
        intent.maxExecutorFee = 0.01 ether;
        intent.nonce = nonce;
        intent.deadline = deadline;
    }

    function _signDigest(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {SessionKeyValidationModule} from "../../src/erc6900/SessionKeyValidationModule.sol";
import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";
import {ModuleEntity, ValidationConfig} from "../../src/erc6900/ModuleTypes.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";

contract SessionMockAccount is IERC6551Account {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function setOwner(address newOwner) external {
        _owner = newOwner;
    }

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (block.chainid, address(0xBEEF), 1);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function nonce() external pure returns (uint256) {
        return 0;
    }

    function isValidSigner(address, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xffffffff);
    }
}

contract SessionMockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract PositionMSCASessionHarness is PositionMSCA {
    uint256 private _chainId;
    address private _tokenContract;
    uint256 private _tokenId;

    constructor(address entryPoint_) PositionMSCA(entryPoint_) {}

    function setTokenData(uint256 chainId, address tokenContract, uint256 tokenId) external {
        _chainId = chainId;
        _tokenContract = tokenContract;
        _tokenId = tokenId;
    }

    function token() public view override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (_chainId, _tokenContract, _tokenId);
    }

    function ping() external pure returns (bytes4) {
        return 0x11223344;
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }
}

/// @notice Property-style tests for session-key validation module
/// forge-config: default.fuzz.runs = 100
contract SessionKeyValidationModulePropertyTest is Test {
    bytes4 private constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint32 private constant ENTITY_ID = 7;

    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    bytes4 private constant PING_SELECTOR = PositionMSCASessionHarness.ping.selector;
    bytes4 private constant INNER_ALLOWED_SELECTOR = bytes4(keccak256("allowedInner()"));
    bytes4 private constant INNER_BLOCKED_SELECTOR = bytes4(keccak256("blockedInner()"));

    bytes32 private constant USER_OP_TAG = keccak256("EQUALIS_SESSION_USEROP_V1");
    bytes32 private constant RUNTIME_TAG = keccak256("EQUALIS_SESSION_RUNTIME_V1");
    bytes32 private constant SIGNATURE_TAG = keccak256("EQUALIS_SESSION_SIG_V1");

    uint256 private constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _buildUserOp(address sender, bytes memory callData, bytes memory signature)
        internal
        pure
        returns (PackedUserOperation memory userOp)
    {
        userOp = PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    function _userOpDigest(
        SessionKeyValidationModule module,
        address account,
        uint32 entityId,
        bytes32 userOpHash
    ) internal view returns (bytes32) {
        bytes32 payloadHash =
            keccak256(abi.encode(USER_OP_TAG, block.chainid, address(module), account, entityId, userOpHash));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
    }

    function _runtimeDigest(
        SessionKeyValidationModule module,
        address account,
        uint32 entityId,
        address sender,
        uint256 value,
        bytes memory data
    ) internal view returns (bytes32) {
        bytes32 payloadHash = keccak256(
            abi.encode(RUNTIME_TAG, block.chainid, address(module), account, entityId, sender, value, keccak256(data))
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
    }

    function _signatureDigest(SessionKeyValidationModule module, address account, uint32 entityId, bytes32 hash)
        internal
        view
        returns (bytes32)
    {
        bytes32 payloadHash = keccak256(abi.encode(SIGNATURE_TAG, block.chainid, address(module), account, entityId, hash));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
    }

    function _sign(uint256 key, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _asModuleSig(address sessionKey, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encode(sessionKey, sig);
    }

    function _emptyTargetRules() internal pure returns (SessionKeyValidationModule.TargetSelectorRule[] memory rules) {
        rules = new SessionKeyValidationModule.TargetSelectorRule[](0);
    }

    /// @notice **Feature: erc6900-modular-tba, Session Key Policy Enforcement**
    /// @notice Configured session keys can validate execute() calls within policy bounds
    function testProperty_SessionKeyUserOpValidationSuccess(
        uint256 ownerKey,
        uint256 sessionKey,
        address allowedTarget,
        uint96 callValue
    ) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);
        vm.assume(allowedTarget != address(0));

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](1);
        targets[0] = allowedTarget;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        uint256 maxValuePerCall = uint256(callValue) + 1;
        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            maxValuePerCall,
            0,
            targets,
            selectors,
            _emptyTargetRules()
        );

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, allowedTarget, uint256(callValue), bytes(""));
        bytes32 userOpHash = keccak256("session-userop-ok");
        bytes32 digest = _userOpDigest(module, address(account), ENTITY_ID, userOpHash);

        bytes memory moduleSig = _asModuleSig(sessionSigner, _sign(sessionKey, digest));
        PackedUserOperation memory userOp = _buildUserOp(address(account), callData, moduleSig);

        uint256 validationData = module.validateUserOp(ENTITY_ID, userOp, userOpHash);
        assertEq(validationData, 0, "session key userOp should validate");
    }

    function testProperty_SessionKeyUserOpValidationRejectsInvalidPolicy(
        uint256 ownerKey,
        uint256 sessionKey,
        uint256 otherKey,
        address allowedTarget,
        address disallowedTarget
    ) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        otherKey = bound(otherKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey && sessionKey != otherKey && ownerKey != otherKey);
        vm.assume(allowedTarget != address(0));
        vm.assume(disallowedTarget != address(0) && disallowedTarget != allowedTarget);

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);
        address otherSigner = vm.addr(otherKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](1);
        targets[0] = allowedTarget;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            1 ether,
            0,
            targets,
            selectors,
            _emptyTargetRules()
        );

        bytes32 userOpHash = keccak256("session-userop-invalid");
        bytes memory disallowedCall = abi.encodeWithSelector(EXECUTE_SELECTOR, disallowedTarget, 0.1 ether, bytes(""));
        bytes32 digest = _userOpDigest(module, address(account), ENTITY_ID, userOpHash);

        bytes memory badTargetSig = _asModuleSig(sessionSigner, _sign(sessionKey, digest));
        PackedUserOperation memory opBadTarget = _buildUserOp(address(account), disallowedCall, badTargetSig);
        assertEq(module.validateUserOp(ENTITY_ID, opBadTarget, userOpHash), 1, "disallowed target should fail");

        bytes memory highValueCall = abi.encodeWithSelector(EXECUTE_SELECTOR, allowedTarget, 2 ether, bytes(""));
        bytes memory highValueSig = _asModuleSig(sessionSigner, _sign(sessionKey, digest));
        PackedUserOperation memory opHighValue = _buildUserOp(address(account), highValueCall, highValueSig);
        assertEq(module.validateUserOp(ENTITY_ID, opHighValue, userOpHash), 1, "value above max should fail");

        bytes memory badSignerSig = _asModuleSig(otherSigner, _sign(otherKey, digest));
        PackedUserOperation memory opBadSigner = _buildUserOp(
            address(account),
            abi.encodeWithSelector(EXECUTE_SELECTOR, allowedTarget, 0.1 ether, bytes("")),
            badSignerSig
        );
        assertEq(module.validateUserOp(ENTITY_ID, opBadSigner, userOpHash), 1, "unauthorized signer should fail");
    }

    function testProperty_SessionKeyPolicyOwnerControls(uint256 ownerKey, uint256 sessionKey, address nonOwner)
        public
    {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);
        vm.assume(nonOwner != address(0) && nonOwner != owner);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(SessionKeyValidationModule.NotAccountOwner.selector, address(account), nonOwner, owner)
        );
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            0,
            0,
            new address[](0),
            new bytes4[](0),
            _emptyTargetRules()
        );

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            0,
            0,
            new address[](0),
            new bytes4[](0),
            _emptyTargetRules()
        );

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(SessionKeyValidationModule.NotAccountOwner.selector, address(account), nonOwner, owner)
        );
        module.revokeSessionKey(address(account), ENTITY_ID, sessionSigner);

        vm.prank(owner);
        module.revokeSessionKey(address(account), ENTITY_ID, sessionSigner);
    }

    function testProperty_SessionKeyRuntimeAndERC1271Validation(uint256 ownerKey, uint256 sessionKey, address target)
        public
    {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);
        vm.assume(target != address(0));

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            1 ether,
            0,
            targets,
            selectors,
            _emptyTargetRules()
        );

        bytes memory data = abi.encodeWithSelector(EXECUTE_SELECTOR, target, 0.25 ether, bytes(""));
        address runtimeSender = address(0xCAFE);
        bytes32 runtimeDigest = _runtimeDigest(module, address(account), ENTITY_ID, runtimeSender, 0, data);
        bytes memory runtimeAuth = _asModuleSig(sessionSigner, _sign(sessionKey, runtimeDigest));

        module.validateRuntime(address(account), ENTITY_ID, runtimeSender, 0, data, runtimeAuth);

        bytes32 messageHash = keccak256("session-erc1271");
        bytes32 sigDigest = _signatureDigest(module, address(account), ENTITY_ID, messageHash);
        bytes memory signature = _asModuleSig(sessionSigner, _sign(sessionKey, sigDigest));
        assertEq(
            module.validateSignature(address(account), ENTITY_ID, address(0), messageHash, signature),
            ERC1271_MAGICVALUE,
            "session key should pass ERC-1271"
        );

        vm.prank(owner);
        module.revokeSessionKey(address(account), ENTITY_ID, sessionSigner);

        vm.expectRevert(
            abi.encodeWithSelector(
                SessionKeyValidationModule.SessionValidationFailed.selector,
                address(account),
                ENTITY_ID,
                sessionSigner
            )
        );
        module.validateRuntime(address(account), ENTITY_ID, runtimeSender, 0, data, runtimeAuth);
    }

    /// @notice **Feature: erc6900-modular-tba, Session Key Integration with PositionMSCA**
    /// @notice Account-level validateUserOp accepts wrapped ModuleEntity + session signature
    function testIntegration_PositionMSCAWithSessionValidation(uint256 ownerKey, uint256 sessionKey) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);
        address entryPoint = address(0x1234);

        SessionMockPositionNFT nft = new SessionMockPositionNFT();
        uint256 tokenId = nft.mint(owner);

        PositionMSCASessionHarness account = new PositionMSCASessionHarness(entryPoint);
        account.setTokenData(block.chainid, address(nft), tokenId);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        ValidationConfig config = ValidationConfigLib.pack(address(module), ENTITY_ID, false, false, true);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PING_SELECTOR;

        vm.prank(owner);
        account.installValidation(config, selectors, "", new bytes[](0));

        bytes4[] memory policySelectors = new bytes4[](1);
        policySelectors[0] = PING_SELECTOR;

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            0,
            0,
            new address[](0),
            policySelectors,
            _emptyTargetRules()
        );

        bytes memory callData = abi.encodeWithSelector(PING_SELECTOR);
        bytes32 userOpHash = keccak256("session-integration-op");
        bytes32 digest = _userOpDigest(module, address(account), ENTITY_ID, userOpHash);
        bytes memory moduleSig = _asModuleSig(sessionSigner, _sign(sessionKey, digest));
        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), ENTITY_ID);
        bytes memory wrappedSig = abi.encode(validationFunction, moduleSig);

        PackedUserOperation memory userOp = _buildUserOp(address(account), callData, wrappedSig);

        vm.prank(entryPoint);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(validationData, 0, "wrapped session signature should validate through account");
    }

    function testProperty_SessionKeyCumulativeBudgetEnforced(uint256 ownerKey, uint256 sessionKey, address target)
        public
    {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);
        vm.assume(target != address(0));

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            1 ether,
            1 ether,
            targets,
            selectors,
            _emptyTargetRules()
        );

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, target, 0.6 ether, bytes(""));

        bytes32 hash1 = keccak256("budget-1");
        bytes memory sig1 = _asModuleSig(sessionSigner, _sign(sessionKey, _userOpDigest(module, address(account), ENTITY_ID, hash1)));
        PackedUserOperation memory op1 = _buildUserOp(address(account), callData, sig1);
        assertEq(module.validateUserOp(ENTITY_ID, op1, hash1), 0, "first spend should pass");

        bytes32 hash2 = keccak256("budget-2");
        bytes memory sig2 = _asModuleSig(sessionSigner, _sign(sessionKey, _userOpDigest(module, address(account), ENTITY_ID, hash2)));
        PackedUserOperation memory op2 = _buildUserOp(address(account), callData, sig2);
        assertEq(module.validateUserOp(ENTITY_ID, op2, hash2), 1, "second spend should exceed cumulative budget");
    }

    function testProperty_SessionKeyPerTargetSelectorConstraints(
        uint256 ownerKey,
        uint256 sessionKey,
        address target,
        address otherTarget
    ) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);
        vm.assume(target != address(0));
        vm.assume(otherTarget != address(0) && otherTarget != target);

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = otherTarget;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        SessionKeyValidationModule.TargetSelectorRule[] memory targetRules =
            new SessionKeyValidationModule.TargetSelectorRule[](1);
        bytes4[] memory innerSelectors = new bytes4[](1);
        innerSelectors[0] = INNER_ALLOWED_SELECTOR;
        targetRules[0] = SessionKeyValidationModule.TargetSelectorRule({target: target, selectors: innerSelectors});

        vm.prank(owner);
        module.setSessionKeyPolicy(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            0,
            1 ether,
            0,
            targets,
            selectors,
            targetRules
        );

        bytes memory allowedCall =
            abi.encodeWithSelector(EXECUTE_SELECTOR, target, 0, abi.encodeWithSelector(INNER_ALLOWED_SELECTOR));
        bytes32 allowedHash = keccak256("inner-allowed");
        bytes memory allowedSig =
            _asModuleSig(sessionSigner, _sign(sessionKey, _userOpDigest(module, address(account), ENTITY_ID, allowedHash)));
        PackedUserOperation memory allowedOp = _buildUserOp(address(account), allowedCall, allowedSig);
        assertEq(module.validateUserOp(ENTITY_ID, allowedOp, allowedHash), 0, "allowed inner selector should pass");

        bytes memory blockedCall =
            abi.encodeWithSelector(EXECUTE_SELECTOR, target, 0, abi.encodeWithSelector(INNER_BLOCKED_SELECTOR));
        bytes32 blockedHash = keccak256("inner-blocked");
        bytes memory blockedSig =
            _asModuleSig(sessionSigner, _sign(sessionKey, _userOpDigest(module, address(account), ENTITY_ID, blockedHash)));
        PackedUserOperation memory blockedOp = _buildUserOp(address(account), blockedCall, blockedSig);
        assertEq(module.validateUserOp(ENTITY_ID, blockedOp, blockedHash), 1, "blocked inner selector should fail");

        bytes memory otherTargetCall =
            abi.encodeWithSelector(EXECUTE_SELECTOR, otherTarget, 0, abi.encodeWithSelector(INNER_BLOCKED_SELECTOR));
        bytes32 otherHash = keccak256("inner-other-target");
        bytes memory otherSig =
            _asModuleSig(sessionSigner, _sign(sessionKey, _userOpDigest(module, address(account), ENTITY_ID, otherHash)));
        PackedUserOperation memory otherOp = _buildUserOp(address(account), otherTargetCall, otherSig);
        assertEq(module.validateUserOp(ENTITY_ID, otherOp, otherHash), 0, "other target has no inner selector constraint");
    }

    function testProperty_SessionKeyPolicyWithDurationExpires(
        uint256 ownerKey,
        uint256 sessionKey,
        address allowedTarget
    ) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        sessionKey = bound(sessionKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != sessionKey);
        vm.assume(allowedTarget != address(0));

        address owner = vm.addr(ownerKey);
        address sessionSigner = vm.addr(sessionKey);

        SessionKeyValidationModule module = new SessionKeyValidationModule();
        SessionMockAccount account = new SessionMockAccount(owner);

        address[] memory targets = new address[](1);
        targets[0] = allowedTarget;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        uint48 ttl = 1 hours;
        vm.prank(owner);
        module.setSessionKeyPolicyWithDuration(
            address(account),
            ENTITY_ID,
            sessionSigner,
            0,
            ttl,
            1 ether,
            0,
            targets,
            selectors,
            _emptyTargetRules()
        );

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, allowedTarget, 0.2 ether, bytes(""));
        bytes32 userOpHash = keccak256("session-duration");

        bytes32 digestBefore = _userOpDigest(module, address(account), ENTITY_ID, userOpHash);
        bytes memory sigBefore = _asModuleSig(sessionSigner, _sign(sessionKey, digestBefore));
        PackedUserOperation memory opBefore = _buildUserOp(address(account), callData, sigBefore);
        assertTrue(module.validateUserOp(ENTITY_ID, opBefore, userOpHash) != 1, "session key should validate before expiry");

        vm.warp(block.timestamp + ttl + 1);

        bytes32 digestAfter = _userOpDigest(module, address(account), ENTITY_ID, userOpHash);
        bytes memory sigAfter = _asModuleSig(sessionSigner, _sign(sessionKey, digestAfter));
        PackedUserOperation memory opAfter = _buildUserOp(address(account), callData, sigAfter);
        assertEq(module.validateUserOp(ENTITY_ID, opAfter, userOpHash), 1, "session key should fail after expiry");
    }
}

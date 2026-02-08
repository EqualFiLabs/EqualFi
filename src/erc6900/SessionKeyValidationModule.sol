// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {IERC165} from "../interfaces/IERC165.sol";
import {IERC6551Account} from "../interfaces/IERC6551Account.sol";
import {IERC6900Module} from "./IERC6900Module.sol";
import {IERC6900ValidationModule} from "./IERC6900ValidationModule.sol";
import {Call} from "./ModuleTypes.sol";

/// @title SessionKeyValidationModule
/// @notice ERC-6900 validation module for scoped session-key delegation
contract SessionKeyValidationModule is IERC6900ValidationModule {
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    bytes4 internal constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    bytes4 internal constant EXECUTE_BATCH_SELECTOR = bytes4(keccak256("executeBatch((address,uint256,bytes)[])"));
    bytes4 internal constant EXECUTE_OPERATION_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes,uint8)"));

    bytes32 internal constant USER_OP_TAG = keccak256("EQUALIS_SESSION_USEROP_V1");
    bytes32 internal constant RUNTIME_TAG = keccak256("EQUALIS_SESSION_RUNTIME_V1");
    bytes32 internal constant SIGNATURE_TAG = keccak256("EQUALIS_SESSION_SIG_V1");

    struct SessionPolicy {
        bool active;
        uint48 validAfter;
        uint48 validUntil;
        uint256 maxValuePerCall;
        uint256 cumulativeValueLimit;
    }

    struct TargetSelectorRule {
        address target;
        bytes4[] selectors;
    }

    mapping(bytes32 => uint64) private _policyNonce;
    mapping(bytes32 => SessionPolicy) private _policies;
    mapping(bytes32 => uint256) private _cumulativeValueUsed;
    mapping(bytes32 => uint256) private _targetCounts;
    mapping(bytes32 => uint256) private _selectorCounts;
    mapping(bytes32 => uint256) private _targetSelectorRuleCount;
    mapping(bytes32 => mapping(address => bool)) private _allowedTargets;
    mapping(bytes32 => mapping(bytes4 => bool)) private _allowedSelectors;
    mapping(bytes32 => mapping(address => uint256)) private _targetSelectorCounts;
    mapping(bytes32 => mapping(address => mapping(bytes4 => bool))) private _allowedTargetSelectors;
    mapping(address => mapping(uint32 => uint64)) private _accountEntityEpoch;

    error NotAccountOwner(address account, address caller, address owner);
    error InvalidSessionKey(address sessionKey);
    error InvalidPolicyWindow(uint48 validAfter, uint48 validUntil);
    error InvalidPolicyDuration(uint48 durationSeconds);
    error EmptySelectorPolicy();
    error MissingTargetAllowlistForExecutionSelectors();
    error SessionValidationFailed(address account, uint32 entityId, address sessionKey);

    event SessionKeyPolicySet(
        address indexed account,
        uint32 indexed entityId,
        address indexed sessionKey,
        uint64 policyNonce,
        uint48 validAfter,
        uint48 validUntil,
        uint256 maxValuePerCall,
        uint256 cumulativeValueLimit,
        uint256 targetCount,
        uint256 selectorCount,
        uint256 targetSelectorRuleCount
    );

    event SessionKeyRevoked(
        address indexed account,
        uint32 indexed entityId,
        address indexed sessionKey,
        uint64 policyNonce
    );

    event SessionBudgetConsumed(
        address indexed account,
        uint32 indexed entityId,
        address indexed sessionKey,
        uint64 policyNonce,
        uint256 amount,
        uint256 cumulativeValueUsed
    );

    event SessionKeyEpochRevoked(address indexed account, uint32 indexed entityId, uint64 epoch);

    function onInstall(bytes calldata) external pure override {}

    function onUninstall(bytes calldata) external pure override {}

    function moduleId() external pure override returns (string memory) {
        return "equallend.session-validation.1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC6900Module).interfaceId
            || interfaceId == type(IERC6900ValidationModule).interfaceId;
    }

    function setSessionKeyPolicy(
        address account,
        uint32 entityId,
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        uint256 maxValuePerCall,
        uint256 cumulativeValueLimit,
        address[] calldata allowedTargets_,
        bytes4[] calldata allowedSelectors_,
        TargetSelectorRule[] calldata targetSelectorRules
    ) external {
        _setSessionKeyPolicy(
            account,
            entityId,
            sessionKey,
            validAfter,
            validUntil,
            maxValuePerCall,
            cumulativeValueLimit,
            allowedTargets_,
            allowedSelectors_,
            targetSelectorRules
        );
    }

    function setSessionKeyPolicyWithDuration(
        address account,
        uint32 entityId,
        address sessionKey,
        uint48 validAfter,
        uint48 durationSeconds,
        uint256 maxValuePerCall,
        uint256 cumulativeValueLimit,
        address[] calldata allowedTargets_,
        bytes4[] calldata allowedSelectors_,
        TargetSelectorRule[] calldata targetSelectorRules
    ) external {
        uint48 validUntil = 0;
        if (durationSeconds != 0) {
            if (durationSeconds > type(uint48).max - uint48(block.timestamp)) {
                revert InvalidPolicyDuration(durationSeconds);
            }
            validUntil = uint48(block.timestamp) + durationSeconds;
        }

        _setSessionKeyPolicy(
            account,
            entityId,
            sessionKey,
            validAfter,
            validUntil,
            maxValuePerCall,
            cumulativeValueLimit,
            allowedTargets_,
            allowedSelectors_,
            targetSelectorRules
        );
    }

    function _setSessionKeyPolicy(
        address account,
        uint32 entityId,
        address sessionKey,
        uint48 validAfter,
        uint48 validUntil,
        uint256 maxValuePerCall,
        uint256 cumulativeValueLimit,
        address[] calldata allowedTargets_,
        bytes4[] calldata allowedSelectors_,
        TargetSelectorRule[] calldata targetSelectorRules
    ) internal {
        _requireAccountOwner(account);
        if (sessionKey == address(0)) {
            revert InvalidSessionKey(sessionKey);
        }
        if (allowedSelectors_.length == 0) {
            revert EmptySelectorPolicy();
        }
        if (_hasExecutionSelector(allowedSelectors_) && allowedTargets_.length == 0) {
            revert MissingTargetAllowlistForExecutionSelectors();
        }
        if (validUntil != 0 && validUntil <= validAfter) {
            revert InvalidPolicyWindow(validAfter, validUntil);
        }

        bytes32 baseKey = _basePolicyKey(account, entityId, sessionKey);
        uint64 nonce = _policyNonce[baseKey] + 1;
        _policyNonce[baseKey] = nonce;

        bytes32 policyKey = _resolvedPolicyKey(baseKey, nonce);
        _policies[policyKey] = SessionPolicy({
            active: true,
            validAfter: validAfter,
            validUntil: validUntil,
            maxValuePerCall: maxValuePerCall,
            cumulativeValueLimit: cumulativeValueLimit
        });

        uint256 targetCount = allowedTargets_.length;
        uint256 selectorCount = allowedSelectors_.length;
        uint256 targetSelectorRuleCount = targetSelectorRules.length;
        _targetCounts[policyKey] = targetCount;
        _selectorCounts[policyKey] = selectorCount;
        _targetSelectorRuleCount[policyKey] = targetSelectorRuleCount;

        for (uint256 i = 0; i < targetCount; i++) {
            _allowedTargets[policyKey][allowedTargets_[i]] = true;
        }
        for (uint256 i = 0; i < selectorCount; i++) {
            _allowedSelectors[policyKey][allowedSelectors_[i]] = true;
        }

        for (uint256 i = 0; i < targetSelectorRuleCount; i++) {
            address target = targetSelectorRules[i].target;
            bytes4[] calldata selectors = targetSelectorRules[i].selectors;
            uint256 count = selectors.length;
            _targetSelectorCounts[policyKey][target] = count;
            for (uint256 j = 0; j < count; j++) {
                _allowedTargetSelectors[policyKey][target][selectors[j]] = true;
            }
        }

        emit SessionKeyPolicySet(
            account,
            entityId,
            sessionKey,
            nonce,
            validAfter,
            validUntil,
            maxValuePerCall,
            cumulativeValueLimit,
            targetCount,
            selectorCount,
            targetSelectorRuleCount
        );
    }

    function revokeSessionKey(address account, uint32 entityId, address sessionKey) external {
        _requireAccountOwner(account);
        if (sessionKey == address(0)) {
            revert InvalidSessionKey(sessionKey);
        }

        bytes32 baseKey = _basePolicyKey(account, entityId, sessionKey);
        uint64 nonce = _policyNonce[baseKey] + 1;
        _policyNonce[baseKey] = nonce;

        emit SessionKeyRevoked(account, entityId, sessionKey, nonce);
    }

    function revokeAllSessionKeys(address account, uint32 entityId) external {
        _requireAccountOwner(account);
        uint64 nextEpoch = _accountEntityEpoch[account][entityId] + 1;
        _accountEntityEpoch[account][entityId] = nextEpoch;
        emit SessionKeyEpochRevoked(account, entityId, nextEpoch);
    }

    function getSessionPolicyEpoch(address account, uint32 entityId) external view returns (uint64) {
        return _accountEntityEpoch[account][entityId];
    }

    function getSessionKeyPolicy(address account, uint32 entityId, address sessionKey)
        external
        view
        returns (
            SessionPolicy memory policy,
            uint64 nonce,
            uint256 targetCount,
            uint256 selectorCount,
            uint256 targetSelectorRuleCount,
            uint256 cumulativeValueUsed
        )
    {
        bytes32 baseKey = _basePolicyKey(account, entityId, sessionKey);
        nonce = _policyNonce[baseKey];
        bytes32 policyKey = _resolvedPolicyKey(baseKey, nonce);
        policy = _policies[policyKey];
        targetCount = _targetCounts[policyKey];
        selectorCount = _selectorCounts[policyKey];
        targetSelectorRuleCount = _targetSelectorRuleCount[policyKey];
        cumulativeValueUsed = _cumulativeValueUsed[policyKey];
    }

    function validateUserOp(uint32 entityId, PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        override
        returns (uint256)
    {
        (address sessionKey, bytes memory sessionSignature) = abi.decode(userOp.signature, (address, bytes));
        (SessionPolicy memory policy, bytes32 policyKey) = _resolveActivePolicy(userOp.sender, entityId, sessionKey);
        if (!_isPolicyActive(policy)) {
            return SIG_VALIDATION_FAILED;
        }

        (bool permitted, uint256 spendAmount) = _isCallPermitted(policyKey, policy, userOp.callData);
        if (!permitted) {
            return SIG_VALIDATION_FAILED;
        }
        if (!_isBudgetPermitted(policyKey, policy, spendAmount)) {
            return SIG_VALIDATION_FAILED;
        }

        bytes32 digest = _userOpDigest(userOp.sender, entityId, userOpHash);
        if (!_isValidSigner(sessionKey, digest, sessionSignature)) {
            return SIG_VALIDATION_FAILED;
        }

        _consumeBudget(userOp.sender, entityId, sessionKey, policyKey, spendAmount);
        return _packValidationData(address(0), policy.validUntil, policy.validAfter);
    }

    function validateRuntime(
        address account,
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) external override {
        (address sessionKey, bytes memory sessionSignature) = abi.decode(authorization, (address, bytes));
        (SessionPolicy memory policy, bytes32 policyKey) = _resolveActivePolicy(account, entityId, sessionKey);
        (bool permitted, uint256 spendAmount) = _isCallPermitted(policyKey, policy, data);
        if (!_isPolicyActive(policy) || !permitted || !_isBudgetPermitted(policyKey, policy, spendAmount)) {
            revert SessionValidationFailed(account, entityId, sessionKey);
        }

        bytes32 digest = _runtimeDigest(account, entityId, sender, value, data);
        if (!_isValidSigner(sessionKey, digest, sessionSignature)) {
            revert SessionValidationFailed(account, entityId, sessionKey);
        }

        _consumeBudget(account, entityId, sessionKey, policyKey, spendAmount);
    }

    function validateSignature(
        address account,
        uint32 entityId,
        address,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        (address sessionKey, bytes memory sessionSignature) = abi.decode(signature, (address, bytes));
        (SessionPolicy memory policy,) = _resolveActivePolicy(account, entityId, sessionKey);
        if (!_isPolicyActive(policy)) {
            return bytes4(0xffffffff);
        }

        bytes32 digest = _signatureDigest(account, entityId, hash);
        if (_isValidSigner(sessionKey, digest, sessionSignature)) {
            return ERC1271_MAGICVALUE;
        }
        return bytes4(0xffffffff);
    }

    function _resolveActivePolicy(address account, uint32 entityId, address sessionKey)
        internal
        view
        returns (SessionPolicy memory policy, bytes32 policyKey)
    {
        bytes32 baseKey = _basePolicyKey(account, entityId, sessionKey);
        uint64 nonce = _policyNonce[baseKey];
        policyKey = _resolvedPolicyKey(baseKey, nonce);
        policy = _policies[policyKey];
    }

    function _isPolicyActive(SessionPolicy memory policy) internal view returns (bool) {
        if (!policy.active) {
            return false;
        }
        if (policy.validAfter != 0 && block.timestamp < policy.validAfter) {
            return false;
        }
        if (policy.validUntil != 0 && block.timestamp > policy.validUntil) {
            return false;
        }
        return true;
    }

    function _isCallPermitted(bytes32 policyKey, SessionPolicy memory policy, bytes calldata callData)
        internal
        view
        returns (bool, uint256)
    {
        bytes4 selector = _selectorFromCalldata(callData);

        if (_selectorCounts[policyKey] != 0 && !_allowedSelectors[policyKey][selector]) {
            return (false, 0);
        }

        if (selector == EXECUTE_SELECTOR) {
            (address target, uint256 callValue, bytes memory data) = abi.decode(callData[4:], (address, uint256, bytes));
            if (!_isTargetAndValuePermitted(policyKey, policy, target, callValue)) {
                return (false, 0);
            }
            if (!_isTargetSelectorPermitted(policyKey, target, data)) {
                return (false, 0);
            }
            return (true, callValue);
        }

        if (selector == EXECUTE_OPERATION_SELECTOR) {
            (address target, uint256 callValue, bytes memory data, uint8 operation) =
                abi.decode(callData[4:], (address, uint256, bytes, uint8));
            if (operation != 0) {
                return (false, 0);
            }
            if (!_isTargetAndValuePermitted(policyKey, policy, target, callValue)) {
                return (false, 0);
            }
            if (!_isTargetSelectorPermitted(policyKey, target, data)) {
                return (false, 0);
            }
            return (true, callValue);
        }

        if (selector == EXECUTE_BATCH_SELECTOR) {
            Call[] memory calls = abi.decode(callData[4:], (Call[]));
            uint256 totalValue;
            for (uint256 i = 0; i < calls.length; i++) {
                if (!_isTargetAndValuePermitted(policyKey, policy, calls[i].target, calls[i].value)) {
                    return (false, 0);
                }
                if (!_isTargetSelectorPermitted(policyKey, calls[i].target, calls[i].data)) {
                    return (false, 0);
                }
                totalValue += calls[i].value;
            }
            return (true, totalValue);
        }

        return (true, 0);
    }

    function _isTargetAndValuePermitted(
        bytes32 policyKey,
        SessionPolicy memory policy,
        address target,
        uint256 callValue
    ) internal view returns (bool) {
        if (_targetCounts[policyKey] != 0 && !_allowedTargets[policyKey][target]) {
            return false;
        }
        if (callValue > policy.maxValuePerCall) {
            return false;
        }
        return true;
    }

    function _isTargetSelectorPermitted(bytes32 policyKey, address target, bytes memory data)
        internal
        view
        returns (bool)
    {
        uint256 selectorCount = _targetSelectorCounts[policyKey][target];
        if (selectorCount == 0) {
            return true;
        }

        bytes4 selector = _selectorFromBytes(data);
        return _allowedTargetSelectors[policyKey][target][selector];
    }

    function _isBudgetPermitted(bytes32 policyKey, SessionPolicy memory policy, uint256 spendAmount)
        internal
        view
        returns (bool)
    {
        if (spendAmount == 0 || policy.cumulativeValueLimit == 0) {
            return true;
        }
        return _cumulativeValueUsed[policyKey] + spendAmount <= policy.cumulativeValueLimit;
    }

    function _consumeBudget(
        address account,
        uint32 entityId,
        address sessionKey,
        bytes32 policyKey,
        uint256 spendAmount
    ) internal {
        if (spendAmount == 0) {
            return;
        }
        uint256 used = _cumulativeValueUsed[policyKey] + spendAmount;
        _cumulativeValueUsed[policyKey] = used;

        bytes32 baseKey = _basePolicyKey(account, entityId, sessionKey);
        uint64 nonce = _policyNonce[baseKey];
        emit SessionBudgetConsumed(account, entityId, sessionKey, nonce, spendAmount, used);
    }

    function _requireAccountOwner(address account) internal view {
        address owner = IERC6551Account(account).owner();
        if (msg.sender != owner) {
            revert NotAccountOwner(account, msg.sender, owner);
        }
    }

    function _basePolicyKey(address account, uint32 entityId, address sessionKey) internal view returns (bytes32) {
        return keccak256(abi.encode(account, entityId, sessionKey, _accountEntityEpoch[account][entityId]));
    }

    function _resolvedPolicyKey(bytes32 baseKey, uint64 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseKey, nonce));
    }

    function _selectorFromCalldata(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := calldataload(data.offset)
        }
    }

    function _selectorFromBytes(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _isValidSigner(address signer, bytes32 digest, bytes memory signature) internal pure returns (bool) {
        (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(digest, signature);
        return error == ECDSA.RecoverError.NoError && recovered == signer;
    }

    function _userOpDigest(address account, uint32 entityId, bytes32 userOpHash) internal view returns (bytes32) {
        bytes32 payloadHash = keccak256(
            abi.encode(USER_OP_TAG, block.chainid, address(this), account, entityId, userOpHash)
        );
        return MessageHashUtils.toEthSignedMessageHash(payloadHash);
    }

    function _runtimeDigest(
        address account,
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data
    ) internal view returns (bytes32) {
        bytes32 payloadHash = keccak256(
            abi.encode(RUNTIME_TAG, block.chainid, address(this), account, entityId, sender, value, keccak256(data))
        );
        return MessageHashUtils.toEthSignedMessageHash(payloadHash);
    }

    function _signatureDigest(address account, uint32 entityId, bytes32 hash) internal view returns (bytes32) {
        bytes32 payloadHash = keccak256(
            abi.encode(SIGNATURE_TAG, block.chainid, address(this), account, entityId, hash)
        );
        return MessageHashUtils.toEthSignedMessageHash(payloadHash);
    }

    function _packValidationData(address authorizer, uint48 validUntil, uint48 validAfter)
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(authorizer)) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    function _hasExecutionSelector(bytes4[] calldata selectors) internal pure returns (bool) {
        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            if (
                selector == EXECUTE_SELECTOR || selector == EXECUTE_BATCH_SELECTOR || selector == EXECUTE_OPERATION_SELECTOR
            ) {
                return true;
            }
        }
        return false;
    }
}

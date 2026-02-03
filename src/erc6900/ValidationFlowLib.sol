// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {HookConfig, ModuleEntity, ValidationFlags} from "./ModuleTypes.sol";
import {IERC6900ValidationHookModule} from "./IERC6900ValidationHookModule.sol";
import {IERC6900ValidationModule} from "./IERC6900ValidationModule.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";
import {MSCAStorage} from "./MSCAStorage.sol";

/// @title ValidationFlowLib
/// @notice External helpers for validation routing and flow
library ValidationFlowLib {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    error ValidationNotApplicable(ModuleEntity validationFunction, bytes4 selector);
    error ValidationTypeMismatch(ModuleEntity validationFunction);

    function ensureSelectorAllowed(ModuleEntity validationFunction, bytes4 selector) external view {
        if (!_isSelectorAllowed(validationFunction, selector)) {
            revert ValidationNotApplicable(validationFunction, selector);
        }
    }

    function ensureUserOpValidation(ModuleEntity validationFunction) external view {
        uint8 flags = ValidationFlags.unwrap(MSCAStorage.layout().validationData[validationFunction].flags);
        if ((flags & 1) == 0) {
            revert ValidationTypeMismatch(validationFunction);
        }
    }

    function ensureSignatureValidation(ModuleEntity validationFunction) external view {
        uint8 flags = ValidationFlags.unwrap(MSCAStorage.layout().validationData[validationFunction].flags);
        if ((flags & 2) == 0) {
            revert ValidationTypeMismatch(validationFunction);
        }
    }

    function runUserOpValidation(
        ModuleEntity validationFunction,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256) {
        uint256 validationData = 0;
        validationData = _runUserOpHooks(validationFunction, userOp, userOpHash, validationData);
        validationData = _intersectValidationData(
            validationData,
            _callUserOpValidation(validationFunction, userOp, userOpHash)
        );
        return validationData;
    }

    function runRuntimeValidation(
        ModuleEntity validationFunction,
        address account,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) external {
        _runRuntimeHooks(validationFunction, sender, value, data, authorization);
        _callRuntimeValidation(validationFunction, account, sender, value, data, authorization);
    }

    function runSignatureValidation(
        ModuleEntity validationFunction,
        address account,
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4) {
        _runSignatureHooks(validationFunction, sender, hash, signature);
        return _callSignatureValidation(validationFunction, account, sender, hash, signature);
    }

    function _isSelectorAllowed(ModuleEntity validationFunction, bytes4 selector) private view returns (bool) {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        uint8 flags = ValidationFlags.unwrap(ds.validationData[validationFunction].flags);
        if ((flags & 4) != 0) {
            return true;
        }
        bytes4[] storage selectors = ds.validationData[validationFunction].selectors;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] == selector) {
                return true;
            }
        }
        return false;
    }

    function _runUserOpHooks(
        ModuleEntity validationFunction,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 validationData
    ) private returns (uint256) {
        HookConfig[] storage hooks = MSCAStorage.layout().validationHooks[validationFunction];
        for (uint256 i = 0; i < hooks.length; i++) {
            (address hookModule, uint32 entityId) = _unpackHook(hooks[i]);
            uint256 hookData = IERC6900ValidationHookModule(hookModule).preUserOpValidationHook(
                entityId,
                userOp,
                userOpHash
            );
            validationData = _intersectValidationData(validationData, hookData);
        }
        return validationData;
    }

    function _runRuntimeHooks(
        ModuleEntity validationFunction,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) private {
        HookConfig[] storage hooks = MSCAStorage.layout().validationHooks[validationFunction];
        for (uint256 i = 0; i < hooks.length; i++) {
            (address hookModule, uint32 entityId) = _unpackHook(hooks[i]);
            IERC6900ValidationHookModule(hookModule).preRuntimeValidationHook(
                entityId,
                sender,
                value,
                data,
                authorization
            );
        }
    }

    function _runSignatureHooks(
        ModuleEntity validationFunction,
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) private view {
        HookConfig[] storage hooks = MSCAStorage.layout().validationHooks[validationFunction];
        for (uint256 i = 0; i < hooks.length; i++) {
            (address hookModule, uint32 entityId) = _unpackHook(hooks[i]);
            IERC6900ValidationHookModule(hookModule).preSignatureValidationHook(
                entityId,
                sender,
                hash,
                signature
            );
        }
    }

    function _callUserOpValidation(
        ModuleEntity validationFunction,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) private returns (uint256) {
        (address module, uint32 entityId) = ModuleEntityLib.unpack(validationFunction);
        return IERC6900ValidationModule(module).validateUserOp(entityId, userOp, userOpHash);
    }

    function _callRuntimeValidation(
        ModuleEntity validationFunction,
        address account,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) private {
        (address module, uint32 entityId) = ModuleEntityLib.unpack(validationFunction);
        IERC6900ValidationModule(module).validateRuntime(account, entityId, sender, value, data, authorization);
    }

    function _callSignatureValidation(
        ModuleEntity validationFunction,
        address account,
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) private view returns (bytes4) {
        (address module, uint32 entityId) = ModuleEntityLib.unpack(validationFunction);
        return IERC6900ValidationModule(module).validateSignature(account, entityId, sender, hash, signature);
    }

    function _unpackHook(HookConfig hook) private pure returns (address module, uint32 entityId) {
        bytes25 raw = HookConfig.unwrap(hook);
        (module, entityId) = ModuleEntityLib.unpack(ModuleEntity.wrap(bytes24(raw)));
    }

    function _intersectValidationData(uint256 acc, uint256 next) private pure returns (uint256) {
        (address authA, uint48 untilA, uint48 afterA) = _parseValidationData(acc);
        (address authB, uint48 untilB, uint48 afterB) = _parseValidationData(next);

        if (authA == address(1) || authB == address(1)) {
            return SIG_VALIDATION_FAILED;
        }

        if (authA == address(0)) {
            authA = authB;
        } else if (authB != address(0) && authA != authB) {
            return SIG_VALIDATION_FAILED;
        }

        if (untilA == 0) {
            untilA = type(uint48).max;
        }
        if (untilB == 0) {
            untilB = type(uint48).max;
        }

        uint48 until = untilA < untilB ? untilA : untilB;
        uint48 after_ = afterA > afterB ? afterA : afterB;

        if (until == type(uint48).max) {
            until = 0;
        }

        return _packValidationData(authA, until, after_);
    }

    function _parseValidationData(uint256 data) private pure returns (address authorizer, uint48 validUntil, uint48 validAfter) {
        authorizer = address(uint160(data));
        validUntil = uint48(data >> 160);
        validAfter = uint48(data >> 208);
    }

    function _packValidationData(address authorizer, uint48 validUntil, uint48 validAfter) private pure returns (uint256) {
        return uint256(uint160(authorizer)) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }
}

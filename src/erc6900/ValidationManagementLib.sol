// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {HookConfig, ModuleEntity, ValidationConfig, ValidationFlags} from "./ModuleTypes.sol";
import {IERC6900Module} from "./IERC6900Module.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";
import {MSCAStorage} from "./MSCAStorage.sol";

/// @title ValidationManagementLib
/// @notice External helpers for validation module storage operations
library ValidationManagementLib {
    function decodeValidationConfig(ValidationConfig validationConfig)
        external
        pure
        returns (ModuleEntity validationFunction, address module, uint32 entityId, uint8 flags)
    {
        bytes25 raw = ValidationConfig.unwrap(validationConfig);
        validationFunction = ModuleEntity.wrap(bytes24(raw));
        flags = uint8(uint200(raw));
        (module, entityId) = ModuleEntityLib.unpack(validationFunction);
    }

    function decodeValidationFunction(ModuleEntity validationFunction)
        external
        pure
        returns (address module, uint32 entityId)
    {
        (module, entityId) = ModuleEntityLib.unpack(validationFunction);
    }

    function storeValidationData(ModuleEntity validationFunction, bytes4[] calldata selectors, uint8 flags) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ds.validationData[validationFunction].flags = ValidationFlags.wrap(flags);
        ds.validationData[validationFunction].selectors = selectors;
    }

    function storeValidationHooks(ModuleEntity validationFunction, bytes[] calldata hooks) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        delete ds.validationHooks[validationFunction];
        delete ds.validationExecHooks[validationFunction];

        for (uint256 i = 0; i < hooks.length; i++) {
            HookConfig hook = abi.decode(hooks[i], (HookConfig));
            uint8 hookFlags = uint8(uint200(HookConfig.unwrap(hook)));
            if ((hookFlags & 1) != 0) {
                ds.validationHooks[validationFunction].push(hook);
            } else {
                ds.validationExecHooks[validationFunction].push(hook);
            }
        }
    }

    function markModuleInstalled(address module) external {
        MSCAStorage.layout().installedModules[module] = true;
    }

    function callOnInstall(address module, bytes calldata installData) external {
        if (installData.length > 0) {
            IERC6900Module(module).onInstall(installData);
        }
    }

    function uninstallValidationHooks(
        ModuleEntity validationFunction,
        bytes[] calldata hookUninstallData,
        uint256 hookDataIndex
    ) external returns (uint256) {
        HookConfig[] storage validationHooks = MSCAStorage.layout().validationHooks[validationFunction];
        return _uninstallHookArray(validationHooks, hookUninstallData, hookDataIndex);
    }

    function uninstallExecutionHooks(
        ModuleEntity validationFunction,
        bytes[] calldata hookUninstallData,
        uint256 hookDataIndex
    ) external returns (uint256) {
        HookConfig[] storage executionHooks = MSCAStorage.layout().validationExecHooks[validationFunction];
        return _uninstallHookArray(executionHooks, hookUninstallData, hookDataIndex);
    }

    function clearValidationState(ModuleEntity validationFunction, address module) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        delete ds.validationHooks[validationFunction];
        delete ds.validationExecHooks[validationFunction];
        delete ds.validationData[validationFunction];
        ds.installedModules[module] = false;
    }

    function tryUninstallModule(address module, bytes calldata uninstallData) external returns (bool) {
        try IERC6900Module(module).onUninstall(uninstallData) {
            return true;
        } catch {
            return false;
        }
    }

    function _uninstallHookArray(
        HookConfig[] storage hooks,
        bytes[] calldata hookUninstallData,
        uint256 hookDataIndex
    ) private returns (uint256) {
        for (uint256 i = 0; i < hooks.length; i++) {
            bytes25 raw = HookConfig.unwrap(hooks[i]);
            address hookModule = address(bytes20(raw));
            bytes memory data = hookDataIndex < hookUninstallData.length ? hookUninstallData[hookDataIndex] : bytes("");
            hookDataIndex++;
            try IERC6900Module(hookModule).onUninstall(data) {} catch {}
        }
        return hookDataIndex;
    }
}

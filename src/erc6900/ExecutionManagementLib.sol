// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ExecutionManifest, HookConfig, ManifestExecutionFunction, ManifestExecutionHook, ModuleEntity} from "./ModuleTypes.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAccount, IAccountExecute} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {IERC6551Account} from "../interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../interfaces/IERC6551Executable.sol";
import {IERC6900Account} from "./IERC6900Account.sol";
import {IERC6900Module} from "./IERC6900Module.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";
import {MSCAStorage} from "./MSCAStorage.sol";

/// @title ExecutionManagementLib
/// @notice External helpers for execution module management
library ExecutionManagementLib {
    error NativeSelectorConflict(bytes4 selector);
    error SelectorAlreadyInstalled(bytes4 selector);

    bytes4 private constant ENTRYPOINT_SELECTOR = bytes4(keccak256("entryPoint()"));

    function checkSelectorConflicts(ExecutionManifest calldata manifest) external view {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ManifestExecutionFunction[] calldata functions = manifest.executionFunctions;
        for (uint256 i = 0; i < functions.length; i++) {
            bytes4 selector = functions[i].executionSelector;
            if (_isNativeSelector(selector)) {
                revert NativeSelectorConflict(selector);
            }
            if (ds.executionData[selector].module != address(0)) {
                revert SelectorAlreadyInstalled(selector);
            }
        }
    }

    function storeExecutionData(address module, ExecutionManifest calldata manifest) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ManifestExecutionFunction[] calldata functions = manifest.executionFunctions;
        for (uint256 i = 0; i < functions.length; i++) {
            bytes4 selector = functions[i].executionSelector;
            ds.executionData[selector] = MSCAStorage.ExecutionData({
                module: module,
                skipRuntimeValidation: functions[i].skipRuntimeValidation,
                allowGlobalValidation: functions[i].allowGlobalValidation
            });
        }
    }

    function storeExecutionHooks(address module, ExecutionManifest calldata manifest) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ManifestExecutionHook[] calldata hooks = manifest.executionHooks;
        for (uint256 i = 0; i < hooks.length; i++) {
            uint8 flags = (hooks[i].isPreHook ? 4 : 0) | (hooks[i].isPostHook ? 2 : 0);
            bytes24 packed = ModuleEntity.unwrap(ModuleEntityLib.pack(module, hooks[i].entityId));
            HookConfig hookConfig = HookConfig.wrap(bytes25(packed) | bytes25(uint200(flags)));
            ds.selectorExecHooks[hooks[i].executionSelector].push(hookConfig);
        }
    }

    function addInterfaceIds(bytes4[] calldata interfaceIds) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        for (uint256 i = 0; i < interfaceIds.length; i++) {
            ds.supportedInterfaces[interfaceIds[i]] += 1;
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

    function removeExecutionData(address module, ExecutionManifest calldata manifest) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ManifestExecutionFunction[] calldata functions = manifest.executionFunctions;
        for (uint256 i = 0; i < functions.length; i++) {
            bytes4 selector = functions[i].executionSelector;
            if (ds.executionData[selector].module == module) {
                delete ds.executionData[selector];
            }
        }
    }

    function removeExecutionHooks(address module, ExecutionManifest calldata manifest) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        ManifestExecutionHook[] calldata hooks = manifest.executionHooks;
        for (uint256 i = 0; i < hooks.length; i++) {
            HookConfig[] storage selectorHooks = ds.selectorExecHooks[hooks[i].executionSelector];
            _removeHooksForModule(selectorHooks, module);
        }
    }

    function removeInterfaceIds(bytes4[] calldata interfaceIds) external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        for (uint256 i = 0; i < interfaceIds.length; i++) {
            uint256 count = ds.supportedInterfaces[interfaceIds[i]];
            if (count > 0) {
                ds.supportedInterfaces[interfaceIds[i]] = count - 1;
            }
        }
    }

    function clearModuleInstalled(address module) external {
        MSCAStorage.layout().installedModules[module] = false;
    }

    function tryOnUninstall(address module, bytes calldata uninstallData) external returns (bool) {
        try IERC6900Module(module).onUninstall(uninstallData) {
            return true;
        } catch {
            return false;
        }
    }

    function _removeHooksForModule(HookConfig[] storage hooks, address module) private {
        uint256 i = 0;
        while (i < hooks.length) {
            address hookModule = address(bytes20(HookConfig.unwrap(hooks[i])));
            if (hookModule == module) {
                hooks[i] = hooks[hooks.length - 1];
                hooks.pop();
            } else {
                unchecked {
                    i++;
                }
            }
        }
    }

    function _isNativeSelector(bytes4 selector) private pure returns (bool) {
        return selector == IERC6900Account.execute.selector ||
            selector == IERC6900Account.executeBatch.selector ||
            selector == IERC6900Account.executeWithRuntimeValidation.selector ||
            selector == IERC6900Account.installExecution.selector ||
            selector == IERC6900Account.uninstallExecution.selector ||
            selector == IERC6900Account.installValidation.selector ||
            selector == IERC6900Account.uninstallValidation.selector ||
            selector == IERC6900Account.accountId.selector ||
            selector == IAccount.validateUserOp.selector ||
            selector == IAccountExecute.executeUserOp.selector ||
            selector == IERC6551Account.token.selector ||
            selector == IERC6551Account.owner.selector ||
            selector == IERC6551Account.nonce.selector ||
            selector == IERC6551Account.isValidSigner.selector ||
            selector == IERC6551Executable.execute.selector ||
            selector == IERC1271.isValidSignature.selector ||
            selector == IERC165.supportsInterface.selector ||
            selector == IERC721Receiver.onERC721Received.selector ||
            selector == ENTRYPOINT_SELECTOR;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {HookConfig, ModuleEntity} from "./ModuleTypes.sol";
import {IERC6900ExecutionHookModule} from "./IERC6900ExecutionHookModule.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";
import {MSCAStorage} from "./MSCAStorage.sol";

/// @title ExecutionFlowLib
/// @notice External helpers for execution hook routing and protection
library ExecutionFlowLib {
    uint256 internal constant MAX_HOOK_DEPTH = 8;
    uint256 internal constant MAX_HOOK_GAS = 13_000_000;

    error MaxHookDepthExceeded();
    error RecursiveHookDetected();
    error HookGasBudgetExceeded(uint256 used);

    function enterHookContext() external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        if (ds.hookExecutionActive) {
            revert RecursiveHookDetected();
        }
        ds.hookExecutionActive = true;
        ds.hookDepth += 1;
        if (ds.hookDepth > MAX_HOOK_DEPTH) {
            revert MaxHookDepthExceeded();
        }
    }

    function exitHookContext() external {
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        if (ds.hookDepth > 0) {
            ds.hookDepth -= 1;
        }
        if (ds.hookDepth == 0) {
            ds.hookExecutionActive = false;
        }
    }

    function runPreHooks(bytes4 selector, address sender, uint256 value, bytes calldata data)
        external
        returns (bytes[] memory preHookData, uint256 gasUsed)
    {
        HookConfig[] storage hooks = MSCAStorage.layout().selectorExecHooks[selector];
        preHookData = new bytes[](hooks.length);
        gasUsed = 0;

        for (uint256 i = 0; i < hooks.length; i++) {
            (address hookModule, uint32 entityId, bool hasPre) = _unpackExecutionHook(hooks[i]);
            if (!hasPre) {
                continue;
            }
            uint256 gasBefore = gasleft();
            preHookData[i] = IERC6900ExecutionHookModule(hookModule).preExecutionHook(
                entityId,
                sender,
                value,
                data
            );
            gasUsed = _accumulateGas(gasUsed, gasBefore);
        }
    }

    function runPostHooks(bytes4 selector, bytes[] memory preHookData, uint256 gasUsed) external {
        HookConfig[] storage hooks = MSCAStorage.layout().selectorExecHooks[selector];
        for (uint256 i = hooks.length; i > 0; i--) {
            (address hookModule, uint32 entityId, bool hasPost) = _unpackPostHook(hooks[i - 1]);
            if (!hasPost) {
                continue;
            }
            uint256 gasBefore = gasleft();
            IERC6900ExecutionHookModule(hookModule).postExecutionHook(entityId, preHookData[i - 1]);
            gasUsed = _accumulateGas(gasUsed, gasBefore);
        }
    }

    function _unpackExecutionHook(HookConfig hook)
        private
        pure
        returns (address module, uint32 entityId, bool hasPre)
    {
        bytes25 raw = HookConfig.unwrap(hook);
        (module, entityId) = ModuleEntityLib.unpack(ModuleEntity.wrap(bytes24(raw)));
        uint8 flags = uint8(uint200(raw));
        hasPre = (flags & 4) != 0;
    }

    function _unpackPostHook(HookConfig hook)
        private
        pure
        returns (address module, uint32 entityId, bool hasPost)
    {
        bytes25 raw = HookConfig.unwrap(hook);
        (module, entityId) = ModuleEntityLib.unpack(ModuleEntity.wrap(bytes24(raw)));
        uint8 flags = uint8(uint200(raw));
        hasPost = (flags & 2) != 0;
    }

    function _accumulateGas(uint256 gasUsed, uint256 gasBefore) private view returns (uint256) {
        uint256 gasAfter = gasleft();
        gasUsed += gasBefore - gasAfter;
        if (gasUsed > MAX_HOOK_GAS) {
            revert HookGasBudgetExceeded(gasUsed);
        }
        return gasUsed;
    }
}

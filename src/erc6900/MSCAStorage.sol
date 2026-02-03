// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {HookConfig, ModuleEntity, ValidationFlags} from "./ModuleTypes.sol";

/// @title MSCAStorage
/// @notice ERC-7201 namespaced storage for the modular account
library MSCAStorage {
    bytes32 internal constant STORAGE_SLOT = bytes32(uint256(keccak256("equallend.msca.storage.v1")) - 1);

    struct ExecutionData {
        address module;
        bool skipRuntimeValidation;
        bool allowGlobalValidation;
    }

    struct ValidationData {
        ValidationFlags flags;
        bytes4[] selectors;
    }

    struct Layout {
        // Selector -> execution module data
        mapping(bytes4 => ExecutionData) executionData;

        // Selector -> execution hooks
        mapping(bytes4 => HookConfig[]) selectorExecHooks;

        // Validation function -> validation data
        mapping(ModuleEntity => ValidationData) validationData;

        // Validation function -> validation hooks
        mapping(ModuleEntity => HookConfig[]) validationHooks;

        // Validation function -> execution hooks (run with this validation)
        mapping(ModuleEntity => HookConfig[]) validationExecHooks;

        // Supported interface IDs (from modules)
        mapping(bytes4 => uint256) supportedInterfaces;

        // Installed modules tracking
        mapping(address => bool) installedModules;

        // Hook execution guards
        uint256 hookDepth;
        bool hookExecutionActive;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}

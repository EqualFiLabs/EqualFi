// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @dev Packed module function reference: module address (20 bytes) + entity ID (4 bytes)
type ModuleEntity is bytes24;

/// @dev Packed validation config: module address (20 bytes) + entity ID (4 bytes) + flags (1 byte)
type ValidationConfig is bytes25;

/// @dev Packed hook config: module address (20 bytes) + entity ID (4 bytes) + flags (1 byte)
type HookConfig is bytes25;

/// @dev Validation flags bit layout:
/// bit 0: isUserOpValidation
/// bit 1: isSignatureValidation
/// bit 2: isGlobal
type ValidationFlags is uint8;

/// @dev Hook flags bit layout:
/// bit 0: hook type (0 = exec, 1 = validation)
/// bit 1: hasPost (exec hooks only)
/// bit 2: hasPre (exec hooks only)
type HookFlags is uint8;

/// @dev Batch call structure
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @dev Execution function manifest entry
struct ManifestExecutionFunction {
    bytes4 executionSelector;
    bool skipRuntimeValidation;
    bool allowGlobalValidation;
}

/// @dev Execution hook manifest entry
struct ManifestExecutionHook {
    bytes4 executionSelector;
    uint32 entityId;
    bool isPreHook;
    bool isPostHook;
}

/// @dev Full execution manifest for module installation
struct ExecutionManifest {
    ManifestExecutionFunction[] executionFunctions;
    ManifestExecutionHook[] executionHooks;
    bytes4[] interfaceIds;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC6900Module} from "./IERC6900Module.sol";

/// @title IERC6900ExecutionHookModule
/// @notice Execution hook module interface for ERC-6900
interface IERC6900ExecutionHookModule is IERC6900Module {
    function preExecutionHook(
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory);

    function postExecutionHook(
        uint32 entityId,
        bytes calldata preExecHookData
    ) external;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ExecutionManifest} from "./ModuleTypes.sol";
import {IERC6900Module} from "./IERC6900Module.sol";

/// @title IERC6900ExecutionModule
/// @notice Execution module interface for ERC-6900
interface IERC6900ExecutionModule is IERC6900Module {
    function executionManifest() external view returns (ExecutionManifest memory);
}

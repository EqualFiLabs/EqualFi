// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Call, ExecutionManifest, ModuleEntity, ValidationConfig} from "./ModuleTypes.sol";

/// @title IERC6900Account
/// @notice Modular account interface for ERC-6900
interface IERC6900Account {
    event ExecutionInstalled(address indexed module, ExecutionManifest manifest);
    event ExecutionUninstalled(address indexed module, bool onUninstallSucceeded, ExecutionManifest manifest);
    event ValidationInstalled(address indexed module, uint32 indexed entityId);
    event ValidationUninstalled(address indexed module, uint32 indexed entityId, bool onUninstallSucceeded);

    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory);

    function executeBatch(Call[] calldata calls) external payable returns (bytes[] memory);

    function executeWithRuntimeValidation(bytes calldata data, bytes calldata authorization)
        external
        payable
        returns (bytes memory);

    function installExecution(address module, ExecutionManifest calldata manifest, bytes calldata installData) external;

    function uninstallExecution(address module, ExecutionManifest calldata manifest, bytes calldata uninstallData)
        external;

    function installValidation(
        ValidationConfig validationConfig,
        bytes4[] calldata selectors,
        bytes calldata installData,
        bytes[] calldata hooks
    ) external;

    function uninstallValidation(
        ModuleEntity validationFunction,
        bytes calldata uninstallData,
        bytes[] calldata hookUninstallData
    ) external;

    function accountId() external view returns (string memory);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC165} from "../interfaces/IERC165.sol";

/// @title IERC6900Module
/// @notice Base interface for ERC-6900 modules
interface IERC6900Module is IERC165 {
    function onInstall(bytes calldata data) external;

    function onUninstall(bytes calldata data) external;

    function moduleId() external view returns (string memory);
}

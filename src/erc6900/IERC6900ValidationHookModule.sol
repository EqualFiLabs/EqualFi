// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IERC6900Module} from "./IERC6900Module.sol";

/// @title IERC6900ValidationHookModule
/// @notice Validation hook module interface for ERC-6900
interface IERC6900ValidationHookModule is IERC6900Module {
    function preUserOpValidationHook(
        uint32 entityId,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256);

    function preRuntimeValidationHook(
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data,
        bytes calldata authorization
    ) external;

    function preSignatureValidationHook(
        uint32 entityId,
        address sender,
        bytes32 hash,
        bytes calldata signature
    ) external view;
}

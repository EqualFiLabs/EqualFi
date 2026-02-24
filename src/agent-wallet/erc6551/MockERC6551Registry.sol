// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";

/// @notice Minimal mock registry for local testing.
contract MockERC6551Registry is IERC6551Registry {
    function createAccount(
        address,
        bytes32,
        uint256,
        address,
        uint256
    ) external pure returns (address accountAddress) {
        accountAddress = address(0);
    }

    function account(
        address,
        bytes32,
        uint256,
        address,
        uint256
    ) external pure returns (address accountAddress) {
        accountAddress = address(0);
    }
}

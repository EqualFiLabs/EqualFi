// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionMSCA} from "./PositionMSCA.sol";

/// @title PositionMSCAImpl
/// @notice Concrete ERC-6900 MSCA implementation for ERC-6551 registry deployments
contract PositionMSCAImpl is PositionMSCA {
    string internal constant ACCOUNT_ID = "equallend.position-tba.1.0.0";

    constructor(address entryPoint_) PositionMSCA(entryPoint_) {}

    function accountId() external pure override returns (string memory) {
        return ACCOUNT_ID;
    }
}

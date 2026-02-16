// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC721BoundMSCA} from "@agent-wallet-core/core/ERC721BoundMSCA.sol";

/// @title PositionMSCAImpl
/// @notice Concrete ERC-6900 MSCA implementation for ERC-6551 registry deployments
contract PositionMSCAImpl is ERC721BoundMSCA {
    string internal constant EQUALFI_ACCOUNT_ID = "equallend.position-tba.1.0.0";

    constructor(address entryPoint_) ERC721BoundMSCA(entryPoint_) {}

    function accountId() external pure override returns (string memory) {
        return EQUALFI_ACCOUNT_ID;
    }
}

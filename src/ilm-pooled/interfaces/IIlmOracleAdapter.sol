// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IIlmOracleAdapter {
    function getPrice(uint256 loanPoolId, uint256 collateralPoolId) external view returns (uint256 priceRay);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IILMPooledLiquidationFacet {
    function pooledLiquidationCall(
        uint256 liquidatorPositionId,
        uint256 borrowerPositionId,
        uint256 marketId,
        uint256 debtToCover
    ) external returns (uint256 debtLiquidated, uint256 collateralSeized);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IILMEvents {
    event IlmMarketCreated(uint256 indexed marketId, uint256 indexed loanPoolId, uint256 indexed collateralPoolId);

    event IlmSupply(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledMinted);
    event IlmWithdraw(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledBurned);
    event IlmBorrow(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledDebtMinted);
    event IlmRepay(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledDebtBurned);

    event IlmLiquidation(
        uint256 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 debtLiquidated,
        uint256 scaledDebtBurned,
        uint256 collateralSeized,
        uint256 badDebtAdded
    );

    event IlmLiquidationRevenue(
        uint256 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 grossSeized,
        uint256 protocolFeeCollateral,
        uint256 netSeized
    );
}

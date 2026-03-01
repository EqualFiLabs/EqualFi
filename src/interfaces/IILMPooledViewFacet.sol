// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmTypes} from "../libraries/IlmTypes.sol";

interface IILMPooledViewFacet {
    function getPooledMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory market);

    function getPooledPosition(uint256 marketId, uint256 positionId)
        external
        view
        returns (IlmTypes.IlmPosition memory position);

    function previewHealthFactor(uint256 marketId, uint256 positionId) external view returns (uint256 hf);

    function previewSupplyBalance(uint256 marketId, uint256 positionId) external view returns (uint256 balance);

    function previewDebtBalance(uint256 marketId, uint256 positionId) external view returns (uint256 debt);

    function getPooledMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256 feeAssets);
}

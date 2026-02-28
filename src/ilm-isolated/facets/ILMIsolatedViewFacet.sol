// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../libraries/LibIlmIsolatedStorage.sol";
import {LibIlmLiquidationMath} from "../libraries/LibIlmLiquidationMath.sol";
import {IIlmIsolatedOracleAdapter} from "../interfaces/IIlmIsolatedOracleAdapter.sol";
import {
    IlmIsolatedMarketNotCreated,
    IlmIsolatedInvalidInput,
    IlmIsolatedOracleStale
} from "../errors/IlmIsolatedErrors.sol";

/// @notice View facet for ILM isolated profile.
contract ILMIsolatedViewFacet {
    function getIsolatedMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory market) {
        market = ds().market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }
    }

    function getIsolatedMarketParams(bytes32 marketId)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedMarketParams memory params)
    {
        _requireMarket(marketId);
        params = ds().marketParams[marketId];
    }

    function getIsolatedPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory position)
    {
        _requireMarket(marketId);
        position = ds().position[marketId][positionKey];
    }

    function isIsolatedHealthy(bytes32 marketId, uint256 positionId) external view returns (bool) {
        _requireMarket(marketId);
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();

        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        IlmIsolatedTypes.IlmIsolatedMarketParams storage params = _ds.marketParams[marketId];
        uint256 oraclePrice = _getFreshPrice(params.oracle, _ds.maxStaleness);
        bytes32 positionKey = _positionKey(positionId);
        IlmIsolatedTypes.IlmIsolatedPosition storage position = _ds.position[marketId][positionKey];

        return LibIlmLiquidationMath.isHealthy(
            position.collateralAssets,
            position.borrowShares,
            market.totalBorrowAssets,
            market.totalBorrowShares,
            oraclePrice,
            params.lltv
        );
    }

    function _requireMarket(bytes32 marketId) internal view {
        if (ds().market[marketId].lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmIsolatedInvalidInput();
        }
        return PositionNFT(ns.positionNFTContract).getPositionKey(positionId);
    }

    function _getFreshPrice(address oracle, uint256 maxStaleness) internal view returns (uint256 price) {
        if (maxStaleness == 0) {
            revert IlmIsolatedInvalidInput();
        }

        uint256 updatedAt;
        (price, updatedAt) = IIlmIsolatedOracleAdapter(oracle).getIsolatedPrice(oracle);
        if (price == 0) {
            revert IlmIsolatedInvalidInput();
        }
        if (updatedAt + maxStaleness < block.timestamp) {
            revert IlmIsolatedOracleStale(updatedAt, maxStaleness);
        }
    }

    function ds() internal pure returns (LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage) {
        return LibIlmIsolatedStorage.s();
    }
}

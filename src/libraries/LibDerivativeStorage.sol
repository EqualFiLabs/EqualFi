// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DerivativeTypes} from "./DerivativeTypes.sol";
import {MamTypes} from "./MamTypes.sol";
import {LibPositionList} from "./LibPositionList.sol";

/// @notice Diamond storage accessors for Position NFT derivatives
library LibDerivativeStorage {
    using LibPositionList for LibPositionList.List;

    bytes32 internal constant DERIVATIVE_STORAGE_POSITION = keccak256("equallend.derivative.storage");

    struct DerivativeStorage {
        DerivativeTypes.DerivativeConfig config;

        mapping(uint256 => DerivativeTypes.AmmAuction) auctions;
        uint256 nextAuctionId;
        bool ammPaused;

        mapping(uint256 => DerivativeTypes.CommunityAuction) communityAuctions;
        mapping(uint256 => mapping(bytes32 => DerivativeTypes.MakerPosition)) communityAuctionMakers;
        uint256 nextCommunityAuctionId;
        bool communityAuctionPaused;

        mapping(uint256 => DerivativeTypes.OptionSeries) optionSeries;
        uint256 nextOptionSeriesId;
        bool optionsPaused;

        mapping(uint256 => DerivativeTypes.FuturesSeries) futuresSeries;
        uint256 nextFuturesSeriesId;
        bool futuresPaused;
        uint64 futuresReclaimGracePeriod;

        // MAM curves
        mapping(uint256 => MamTypes.StoredCurve) curves;
        mapping(uint256 => CurveData) curveData;
        mapping(uint256 => CurveImmutables) curveImmutables;
        mapping(uint256 => CurvePricing) curvePricing;
        mapping(uint256 => bytes32) curveImmutableHash;
        mapping(uint256 => bool) curveBaseIsA;
        uint256 nextCurveId;
        bool mamPaused;

        LibPositionList.List auctionsByPosition;
        LibPositionList.List auctionsGlobal;
        LibPositionList.List auctionsByPool;
        LibPositionList.List auctionsByToken;
        LibPositionList.List auctionsByPair;
        LibPositionList.List communityAuctionsByPosition;
        LibPositionList.List communityAuctionsGlobal;
        LibPositionList.List communityAuctionsByPair;
        LibPositionList.List communityAuctionsByPool;
        LibPositionList.List communityAuctionMakersByAuction;
        LibPositionList.List optionSeriesByPosition;
        LibPositionList.List futuresSeriesByPosition;
        LibPositionList.List curvesByPosition;
        LibPositionList.List curvesGlobal;
        LibPositionList.List curvesByPair;

        mapping(uint256 => uint256) indexFeeAByAuction;
        mapping(uint256 => uint256) indexFeeBByAuction;
        mapping(uint256 => uint256) activeCreditFeeAByAuction;
        mapping(uint256 => uint256) activeCreditFeeBByAuction;
        mapping(uint256 => uint256) treasuryFeesByPool;

        address optionToken;
        address futuresToken;
    }

    struct CurveData {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
    }

    struct CurveImmutables {
        address tokenA;
        address tokenB;
        uint128 maxVolume;
        uint96 salt;
        uint16 feeRateBps;
        bool priceIsQuotePerBase;
        MamTypes.FeeAsset feeAsset;
    }

    struct CurvePricing {
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
    }

    function derivativeStorage() internal pure returns (DerivativeStorage storage ds) {
        bytes32 position = DERIVATIVE_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function addAuction(bytes32 positionKey, uint256 auctionId) internal {
        derivativeStorage().auctionsByPosition.add(positionKey, auctionId);
    }

    function removeAuction(bytes32 positionKey, uint256 auctionId) internal {
        derivativeStorage().auctionsByPosition.remove(positionKey, auctionId);
    }

    function auctionsPage(bytes32 positionKey, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().auctionsByPosition.page(positionKey, offset, limit);
    }

    function addCommunityAuction(bytes32 positionKey, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPosition.add(positionKey, auctionId);
    }

    function removeCommunityAuction(bytes32 positionKey, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPosition.remove(positionKey, auctionId);
    }

    function communityAuctionsPage(bytes32 positionKey, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().communityAuctionsByPosition.page(positionKey, offset, limit);
    }

    function addAuctionGlobal(uint256 auctionId) internal {
        derivativeStorage().auctionsGlobal.add(_globalAuctionsKey(), auctionId);
    }

    function removeAuctionGlobal(uint256 auctionId) internal {
        derivativeStorage().auctionsGlobal.remove(_globalAuctionsKey(), auctionId);
    }

    function auctionsGlobalPage(uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().auctionsGlobal.page(_globalAuctionsKey(), offset, limit);
    }

    function addCommunityAuctionGlobal(uint256 auctionId) internal {
        derivativeStorage().communityAuctionsGlobal.add(_globalCommunityAuctionsKey(), auctionId);
    }

    function removeCommunityAuctionGlobal(uint256 auctionId) internal {
        derivativeStorage().communityAuctionsGlobal.remove(_globalCommunityAuctionsKey(), auctionId);
    }

    function communityAuctionsGlobalPage(uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().communityAuctionsGlobal.page(_globalCommunityAuctionsKey(), offset, limit);
    }

    function addAuctionByPool(uint256 poolId, uint256 auctionId) internal {
        derivativeStorage().auctionsByPool.add(_poolKey(poolId), auctionId);
    }

    function removeAuctionByPool(uint256 poolId, uint256 auctionId) internal {
        derivativeStorage().auctionsByPool.remove(_poolKey(poolId), auctionId);
    }

    function auctionsByPoolPage(uint256 poolId, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().auctionsByPool.page(_poolKey(poolId), offset, limit);
    }

    function addAuctionByToken(address token, uint256 auctionId) internal {
        derivativeStorage().auctionsByToken.add(_tokenKey(token), auctionId);
    }

    function removeAuctionByToken(address token, uint256 auctionId) internal {
        derivativeStorage().auctionsByToken.remove(_tokenKey(token), auctionId);
    }

    function auctionsByTokenPage(address token, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().auctionsByToken.page(_tokenKey(token), offset, limit);
    }

    function addAuctionByPair(address tokenA, address tokenB, uint256 auctionId) internal {
        derivativeStorage().auctionsByPair.add(_pairKey(tokenA, tokenB), auctionId);
    }

    function removeAuctionByPair(address tokenA, address tokenB, uint256 auctionId) internal {
        derivativeStorage().auctionsByPair.remove(_pairKey(tokenA, tokenB), auctionId);
    }

    function auctionsByPairPage(address tokenA, address tokenB, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().auctionsByPair.page(_pairKey(tokenA, tokenB), offset, limit);
    }

    function addCommunityAuctionByPair(address tokenA, address tokenB, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPair.add(_pairKey(tokenA, tokenB), auctionId);
    }

    function removeCommunityAuctionByPair(address tokenA, address tokenB, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPair.remove(_pairKey(tokenA, tokenB), auctionId);
    }

    function communityAuctionsByPairPage(address tokenA, address tokenB, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().communityAuctionsByPair.page(_pairKey(tokenA, tokenB), offset, limit);
    }

    function addCommunityAuctionByPool(uint256 poolId, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPool.add(_poolKey(poolId), auctionId);
    }

    function removeCommunityAuctionByPool(uint256 poolId, uint256 auctionId) internal {
        derivativeStorage().communityAuctionsByPool.remove(_poolKey(poolId), auctionId);
    }

    function communityAuctionsByPoolPage(uint256 poolId, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().communityAuctionsByPool.page(_poolKey(poolId), offset, limit);
    }

    function addCommunityAuctionMaker(uint256 auctionId, uint256 positionId) internal {
        derivativeStorage().communityAuctionMakersByAuction.add(_auctionKey(auctionId), positionId);
    }

    function removeCommunityAuctionMaker(uint256 auctionId, uint256 positionId) internal {
        derivativeStorage().communityAuctionMakersByAuction.remove(_auctionKey(auctionId), positionId);
    }

    function communityAuctionMakersPage(uint256 auctionId, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().communityAuctionMakersByAuction.page(_auctionKey(auctionId), offset, limit);
    }

    function addOptionSeries(bytes32 positionKey, uint256 seriesId) internal {
        derivativeStorage().optionSeriesByPosition.add(positionKey, seriesId);
    }

    function removeOptionSeries(bytes32 positionKey, uint256 seriesId) internal {
        derivativeStorage().optionSeriesByPosition.remove(positionKey, seriesId);
    }

    function optionSeriesPage(bytes32 positionKey, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().optionSeriesByPosition.page(positionKey, offset, limit);
    }

    function addFuturesSeries(bytes32 positionKey, uint256 seriesId) internal {
        derivativeStorage().futuresSeriesByPosition.add(positionKey, seriesId);
    }

    function removeFuturesSeries(bytes32 positionKey, uint256 seriesId) internal {
        derivativeStorage().futuresSeriesByPosition.remove(positionKey, seriesId);
    }

    function futuresSeriesPage(bytes32 positionKey, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().futuresSeriesByPosition.page(positionKey, offset, limit);
    }

    function addCurve(bytes32 positionKey, uint256 curveId) internal {
        derivativeStorage().curvesByPosition.add(positionKey, curveId);
    }

    function removeCurve(bytes32 positionKey, uint256 curveId) internal {
        derivativeStorage().curvesByPosition.remove(positionKey, curveId);
    }

    function curvesPage(bytes32 positionKey, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().curvesByPosition.page(positionKey, offset, limit);
    }

    function addCurveGlobal(uint256 curveId) internal {
        derivativeStorage().curvesGlobal.add(_globalCurvesKey(), curveId);
    }

    function removeCurveGlobal(uint256 curveId) internal {
        derivativeStorage().curvesGlobal.remove(_globalCurvesKey(), curveId);
    }

    function curvesGlobalPage(uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().curvesGlobal.page(_globalCurvesKey(), offset, limit);
    }

    function addCurveByPair(address tokenA, address tokenB, uint256 curveId) internal {
        derivativeStorage().curvesByPair.add(_pairKey(tokenA, tokenB), curveId);
    }

    function removeCurveByPair(address tokenA, address tokenB, uint256 curveId) internal {
        derivativeStorage().curvesByPair.remove(_pairKey(tokenA, tokenB), curveId);
    }

    function curvesByPairPage(address tokenA, address tokenB, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return derivativeStorage().curvesByPair.page(_pairKey(tokenA, tokenB), offset, limit);
    }

    function _poolKey(uint256 poolId) private pure returns (bytes32) {
        return bytes32(poolId);
    }

    function _auctionKey(uint256 auctionId) private pure returns (bytes32) {
        return bytes32(auctionId);
    }

    function _tokenKey(address token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(token0, token1));
    }

    function _globalAuctionsKey() private pure returns (bytes32) {
        return keccak256("amm.auctions.active");
    }

    function _globalCommunityAuctionsKey() private pure returns (bytes32) {
        return keccak256("community.auctions.active");
    }

    function _globalCurvesKey() private pure returns (bytes32) {
        return keccak256("mam.curves.active");
    }
}

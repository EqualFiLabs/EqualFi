// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @notice View helpers tailored for auction management and pool monitoring UI.
contract AuctionManagementViewFacet {
    function getActiveCommunityAuctions(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.communityAuctionsGlobalPage(offset, limit);
    }

    function getCommunityAuctionsByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.communityAuctionsByPairPage(tokenA, tokenB, offset, limit);
    }

    function getCommunityAuctionsByPool(uint256 poolId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.communityAuctionsByPoolPage(poolId, offset, limit);
    }

    function getCommunityAuctionMakers(uint256 auctionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds, bytes32[] memory positionKeys, uint256[] memory shares, uint256 total)
    {
        (positionIds, total) = LibDerivativeStorage.communityAuctionMakersPage(auctionId, offset, limit);
        uint256 count = positionIds.length;
        positionKeys = new bytes32[](count);
        shares = new uint256[](count);

        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        require(ns.nftModeEnabled && ns.positionNFTContract != address(0), "AuctionView: position NFT disabled");
        PositionNFT nft = PositionNFT(ns.positionNFTContract);

        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        for (uint256 i = 0; i < count; i++) {
            uint256 positionId = positionIds[i];
            bytes32 positionKey = nft.getPositionKey(positionId);
            positionKeys[i] = positionKey;
            shares[i] = ds.communityAuctionMakers[auctionId][positionKey].share;
        }
    }

    function getAmmAuctionStatus(uint256 auctionId)
        external
        view
        returns (bool active, bool finalized, bool expired, uint256 timeRemaining, bool canFinalize)
    {
        DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
        active = auction.active && !auction.finalized;
        finalized = auction.finalized;
        expired = block.timestamp >= auction.endTime;
        if (!expired) {
            timeRemaining = auction.endTime - block.timestamp;
        }
        canFinalize = active && expired;
    }

    function getAmmAuctionMakerSummary(uint256 auctionId)
        external
        view
        returns (
            uint256 makerPositionId,
            bytes32 makerPositionKey,
            uint256 reserveA,
            uint256 reserveB,
            uint256 initialReserveA,
            uint256 initialReserveB,
            uint256 makerFeeA,
            uint256 makerFeeB,
            uint256 treasuryFeeA,
            uint256 treasuryFeeB,
            uint16 feeBps,
            DerivativeTypes.FeeAsset feeAsset,
            uint64 startTime,
            uint64 endTime,
            bool active,
            bool finalized
        )
    {
        DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
        makerPositionId = auction.makerPositionId;
        makerPositionKey = auction.makerPositionKey;
        reserveA = auction.reserveA;
        reserveB = auction.reserveB;
        initialReserveA = auction.initialReserveA;
        initialReserveB = auction.initialReserveB;
        makerFeeA = auction.makerFeeAAccrued;
        makerFeeB = auction.makerFeeBAccrued;
        treasuryFeeA = auction.treasuryFeeAAccrued;
        treasuryFeeB = auction.treasuryFeeBAccrued;
        feeBps = auction.feeBps;
        feeAsset = auction.feeAsset;
        startTime = auction.startTime;
        endTime = auction.endTime;
        active = auction.active;
        finalized = auction.finalized;
    }

    function getPoolFeeFlow(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 userFeeIndex, uint256 pendingYield)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "AuctionView: uninit pool");
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        feeIndex = p.feeIndex;
        userFeeIndex = p.userFeeIndex[positionKey];
        pendingYield = LibFeeIndex.pendingYield(pid, positionKey);
    }

    function getPoolHealth(uint256 pid)
        external
        view
        returns (
            uint256 liquidity,
            uint256 totalDeposits,
            uint256 trackedBalance,
            uint256 utilizationBps,
            uint256 feeIndex,
            uint256 maintenanceIndex
        )
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "AuctionView: uninit pool");
        liquidity = LibCurrency.balanceOfSelf(p.underlying);
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        feeIndex = p.feeIndex;
        maintenanceIndex = p.maintenanceIndex;
        if (totalDeposits > 0 && liquidity < totalDeposits) {
            utilizationBps = ((totalDeposits - liquidity) * 10_000) / totalDeposits;
        }
    }

    function getTreasuryFeesByPool(uint256 pid) external view returns (uint256) {
        return LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[pid];
    }

    function getPositionFeeShare(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 shareBps, uint256 userPrincipal, uint256 totalDeposits)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "AuctionView: uninit pool");
        userPrincipal = p.userPrincipal[positionKey];
        totalDeposits = p.totalDeposits;
        if (totalDeposits > 0) {
            shareBps = (userPrincipal * 10_000) / totalDeposits;
        }
    }

    /// @notice Diagnostic: returns backing components used in fee accrual checks.
    function getPoolBacking(uint256 pid)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 trackedBalance,
            uint256 yieldReserve,
            uint256 activeCreditPrincipalTotal,
            uint256 actualBalance
        )
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "AuctionView: uninit pool");
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        yieldReserve = p.yieldReserve;
        activeCreditPrincipalTotal = p.activeCreditPrincipalTotal;
        actualBalance = LibCurrency.balanceOfSelf(p.underlying);
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](10);
        selectorsArr[0] = AuctionManagementViewFacet.getActiveCommunityAuctions.selector;
        selectorsArr[1] = AuctionManagementViewFacet.getCommunityAuctionsByPair.selector;
        selectorsArr[2] = AuctionManagementViewFacet.getCommunityAuctionsByPool.selector;
        selectorsArr[3] = AuctionManagementViewFacet.getCommunityAuctionMakers.selector;
        selectorsArr[4] = AuctionManagementViewFacet.getAmmAuctionStatus.selector;
        selectorsArr[5] = AuctionManagementViewFacet.getAmmAuctionMakerSummary.selector;
        selectorsArr[6] = AuctionManagementViewFacet.getPoolFeeFlow.selector;
        selectorsArr[7] = AuctionManagementViewFacet.getPoolHealth.selector;
        selectorsArr[8] = AuctionManagementViewFacet.getTreasuryFeesByPool.selector;
        selectorsArr[9] = AuctionManagementViewFacet.getPoolBacking.selector;
    }
}

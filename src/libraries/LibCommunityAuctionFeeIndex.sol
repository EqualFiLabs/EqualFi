// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DerivativeTypes} from "./DerivativeTypes.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibDerivativeStorage} from "./LibDerivativeStorage.sol";
import {Types} from "./Types.sol";

/// @notice Fee index accounting for community auctions (1e18 scale).
library LibCommunityAuctionFeeIndex {
    uint256 internal constant INDEX_SCALE = 1e18;

    function accrueTokenAFee(uint256 auctionId, uint256 amount) internal {
        if (amount == 0) return;
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        uint256 totalShares = auction.totalShares;
        if (totalShares == 0) return;

        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + auction.feeIndexRemainderA;
        uint256 delta = dividend / totalShares;
        if (delta == 0) {
            auction.feeIndexRemainderA = dividend;
            return;
        }
        auction.feeIndexA += delta;
        auction.feeIndexRemainderA = dividend - (delta * totalShares);
    }

    function accrueTokenBFee(uint256 auctionId, uint256 amount) internal {
        if (amount == 0) return;
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        uint256 totalShares = auction.totalShares;
        if (totalShares == 0) return;

        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + auction.feeIndexRemainderB;
        uint256 delta = dividend / totalShares;
        if (delta == 0) {
            auction.feeIndexRemainderB = dividend;
            return;
        }
        auction.feeIndexB += delta;
        auction.feeIndexRemainderB = dividend - (delta * totalShares);
    }

    function settleMaker(uint256 auctionId, bytes32 positionKey) internal returns (uint256 feesA, uint256 feesB) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        uint256 share = maker.share;

        if (share > 0) {
            uint256 indexA = auction.feeIndexA;
            uint256 indexB = auction.feeIndexB;

            if (indexA > maker.feeIndexSnapshotA) {
                uint256 deltaA = indexA - maker.feeIndexSnapshotA;
                feesA = Math.mulDiv(share, deltaA, INDEX_SCALE);
            }
            if (indexB > maker.feeIndexSnapshotB) {
                uint256 deltaB = indexB - maker.feeIndexSnapshotB;
                feesB = Math.mulDiv(share, deltaB, INDEX_SCALE);
            }

            if (feesA > 0) {
                Types.PoolData storage poolA = LibAppStorage.s().pools[auction.poolIdA];
                poolA.userAccruedYield[positionKey] += feesA;
            }
            if (feesB > 0) {
                Types.PoolData storage poolB = LibAppStorage.s().pools[auction.poolIdB];
                poolB.userAccruedYield[positionKey] += feesB;
            }
        }

        maker.feeIndexSnapshotA = auction.feeIndexA;
        maker.feeIndexSnapshotB = auction.feeIndexB;
    }

    function pendingFees(uint256 auctionId, bytes32 positionKey) internal view returns (uint256 feesA, uint256 feesB) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        uint256 share = maker.share;
        if (share == 0) return (0, 0);

        uint256 indexA = auction.feeIndexA;
        uint256 indexB = auction.feeIndexB;

        if (indexA > maker.feeIndexSnapshotA) {
            uint256 deltaA = indexA - maker.feeIndexSnapshotA;
            feesA = Math.mulDiv(share, deltaA, INDEX_SCALE);
        }
        if (indexB > maker.feeIndexSnapshotB) {
            uint256 deltaB = indexB - maker.feeIndexSnapshotB;
            feesB = Math.mulDiv(share, deltaB, INDEX_SCALE);
        }
    }

    function snapshotIndexes(uint256 auctionId, bytes32 positionKey) internal {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        maker.feeIndexSnapshotA = auction.feeIndexA;
        maker.feeIndexSnapshotB = auction.feeIndexB;
    }
}

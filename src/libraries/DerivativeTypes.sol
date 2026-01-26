// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Core data structures for Position NFT derivatives
library DerivativeTypes {
    enum FeeAsset {
        TokenIn,
        TokenOut
    }

    struct AmmAuction {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 initialReserveA;
        uint256 initialReserveB;
        uint256 invariant;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        FeeAsset feeAsset;
        uint256 makerFeeAAccrued;
        uint256 makerFeeBAccrued;
        uint256 treasuryFeeAAccrued;
        uint256 treasuryFeeBAccrued;
        bool active;
        bool finalized;
    }

    struct CommunityAuction {
        bytes32 creatorPositionKey;
        uint256 creatorPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint16 feeBps;
        FeeAsset feeAsset;
        uint256 feeIndexA;
        uint256 feeIndexB;
        uint256 feeIndexRemainderA;
        uint256 feeIndexRemainderB;
        uint256 treasuryFeeAAccrued;
        uint256 treasuryFeeBAccrued;
        uint256 indexFeeAAccrued;
        uint256 indexFeeBAccrued;
        uint256 activeCreditFeeAAccrued;
        uint256 activeCreditFeeBAccrued;
        uint256 totalShares;
        uint256 makerCount;
        uint64 startTime;
        uint64 endTime;
        bool active;
        bool finalized;
    }

    struct MakerPosition {
        uint256 share;
        uint256 feeIndexSnapshotA;
        uint256 feeIndexSnapshotB;
        uint256 initialContributionA;
        uint256 initialContributionB;
        bool isParticipant;
    }

    struct OptionSeries {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 underlyingPoolId;
        uint256 strikePoolId;
        address underlyingAsset;
        address strikeAsset;
        uint256 strikePrice;
        uint64 expiry;
        uint256 totalSize;
        uint256 remaining;
        uint256 collateralLocked;
        uint16 createFeeBps;
        uint16 exerciseFeeBps;
        uint16 reclaimFeeBps;
        bool isCall;
        bool isAmerican;
        bool reclaimed;
    }

    struct FuturesSeries {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 underlyingPoolId;
        uint256 quotePoolId;
        address underlyingAsset;
        address quoteAsset;
        uint256 forwardPrice;
        uint64 expiry;
        uint256 totalSize;
        uint256 remaining;
        uint256 underlyingLocked;
        uint16 createFeeBps;
        uint16 exerciseFeeBps;
        uint16 reclaimFeeBps;
        uint64 graceUnlockTime;
        bool isEuropean;
        bool reclaimed;
    }

    struct DerivativeConfig {
        uint64 europeanToleranceSeconds;
        uint64 defaultGracePeriodSeconds;
        uint16 maxFeeBps;
        uint16 minFeeBps;
        uint16 defaultCreateFeeBps;
        uint16 defaultExerciseFeeBps;
        uint16 defaultReclaimFeeBps;
        uint16 ammMakerShareBps;
        uint16 communityMakerShareBps;
        uint16 mamMakerShareBps;
        uint128 defaultCreateFeeFlatWad;
        uint128 defaultExerciseFeeFlatWad;
        uint128 defaultReclaimFeeFlatWad;
        bool requirePositionNFT;
    }

    struct CreateAuctionParams {
        uint256 positionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        FeeAsset feeAsset;
    }

    struct CreateCommunityAuctionParams {
        uint256 positionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        FeeAsset feeAsset;
    }

    struct CreateOptionSeriesParams {
        uint256 positionId;
        uint256 underlyingPoolId;
        uint256 strikePoolId;
        uint256 strikePrice;
        uint64 expiry;
        uint256 totalSize;
        bool isCall;
        bool isAmerican;
        bool useCustomFees;
        uint16 createFeeBps;
        uint16 exerciseFeeBps;
        uint16 reclaimFeeBps;
    }

    struct CreateFuturesSeriesParams {
        uint256 positionId;
        uint256 underlyingPoolId;
        uint256 quotePoolId;
        uint256 forwardPrice;
        uint64 expiry;
        uint256 totalSize;
        bool isEuropean;
        bool useCustomFees;
        uint16 createFeeBps;
        uint16 exerciseFeeBps;
        uint16 reclaimFeeBps;
    }
}

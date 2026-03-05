// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

library LibClAuctionStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalis.cl.community.auction.storage.v1");

    struct ClCommunityAuction {
        uint256 auctionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint24 tickSpacing;
        uint24 swapFee;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 protocolFees0;
        uint128 protocolFees1;
        uint64 startTime;
        uint64 endTime;
        bool initialized;
        bool finalized;
        bool cancelled;
        bytes32 creatorPositionKey;
    }

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }

    struct ClPosition {
        uint96 nonce;
        address operator;
        uint256 auctionId;
        uint256 sourcePositionId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    struct EncumbranceLock {
        uint256 lockedA;
        uint256 lockedB;
    }

    struct CreateClAuctionParams {
        uint256 positionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint24 tickSpacing;
        uint24 swapFee;
        uint160 sqrtPriceX96;
        uint64 startTime;
        uint64 endTime;
    }

    struct MintClPositionParams {
        uint256 auctionId;
        uint256 positionId;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct IncreaseClLiquidityParams {
        uint256 clPositionId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct DecreaseClLiquidityParams {
        uint256 clPositionId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct CollectClFeesParams {
        uint256 clPositionId;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct ClStorage {
        uint256 nextAuctionId;
        mapping(uint256 => ClCommunityAuction) auctions;
        mapping(uint256 => mapping(int24 => TickInfo)) ticks;
        mapping(uint256 => mapping(int16 => uint256)) tickBitmaps;
        mapping(uint256 => ClPosition) positions;
        mapping(uint256 => EncumbranceLock) encumbranceLocks;
        bool creationEnabled;
        bool swapPaused;
        uint24 swapFeeCap;
        mapping(uint24 => bool) allowedTickSpacings;
        address clPositionManager;
    }

    function s() internal pure returns (ClStorage storage cs) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            cs.slot := position
        }
    }
}

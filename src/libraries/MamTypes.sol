// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Core data structures for MAM curves.
library MamTypes {
    /// @notice Execution side relative to tokenA/tokenB.
    enum Side {
        SellAForB,
        SellBForA
    }

    /// @notice Fee asset marker (future-proofed).
    enum FeeAsset {
        TokenIn,
        TokenOut
    }

    /// @notice Canonical curve descriptor used at creation time.
    struct CurveDescriptor {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        bool side; // false: SellAForB, true: SellBForA
        bool priceIsQuotePerBase;
        uint128 maxVolume;
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
        uint32 generation;
        uint16 feeRateBps;
        FeeAsset feeAsset;
        uint96 salt;
    }

    /// @notice Minimal onchain representation for a committed curve.
    struct StoredCurve {
        bytes32 commitment;
        uint128 remainingVolume;
        uint64 endTime;
        uint32 generation;
        bool active;
    }

    /// @notice Mutable-only parameters permitted during curve updates.
    struct CurveUpdateParams {
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
    }

    /// @notice View struct returned by loadCurveForFill (curveId-only flow).
    struct CurveFillView {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        bool baseIsA;
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
        uint16 feeRateBps;
        uint128 remainingVolume;
    }
}

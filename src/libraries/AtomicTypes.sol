// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Shared data structures for Atomic Desk reservations.
library AtomicTypes {
    enum ReservationStatus {
        None,
        Active,
        Settled,
        Refunded
    }

    enum FeePayer {
        Maker,
        Taker
    }

    struct DeskConfig {
        bytes32 positionKey;
        uint256 positionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        bool baseIsA;
        bool active;
        address maker;
    }

    struct Reservation {
        bytes32 reservationId;
        bytes32 deskId;
        bytes32 positionKey;
        uint256 positionId;
        address desk;
        address taker;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        bool baseIsA;
        address asset;
        uint256 amount;
        bytes32 settlementDigest;
        bytes32 hashlock;
        uint256 counter;
        uint64 expiry;
        uint64 createdAt;
        uint16 feeBps;
        FeePayer feePayer;
        ReservationStatus status;
    }

    struct Tranche {
        bytes32 trancheId;
        bytes32 deskId;
        bytes32 positionKey;
        uint256 positionId;
        address maker;
        address asset;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 totalLiquidity;
        uint256 remainingLiquidity;
        uint256 minFill;
        uint16 feeBps;
        FeePayer feePayer;
        uint64 expiry;
        uint64 createdAt;
        bool active;
    }

    struct TakerTranche {
        bytes32 trancheId;
        bytes32 deskId;
        bytes32 positionKey;
        uint256 positionId;
        address taker;
        address asset;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 totalLiquidity;
        uint256 remainingLiquidity;
        uint256 minFill;
        uint16 feeBps;
        FeePayer feePayer;
        uint64 expiry;
        uint64 createdAt;
        bool active;
    }
}

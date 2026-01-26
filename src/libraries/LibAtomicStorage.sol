// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AtomicTypes} from "./AtomicTypes.sol";

/// @notice Storage accessors for Atomic Desk + SettlementEscrow state.
library LibAtomicStorage {
    bytes32 internal constant ATOMIC_STORAGE_POSITION = keccak256("equalx.atomic.storage");

    struct AtomicStorage {
        mapping(bytes32 => AtomicTypes.DeskConfig) desks;
        mapping(bytes32 => AtomicTypes.Reservation) reservations;
        mapping(bytes32 => AtomicTypes.Tranche) tranches;
        mapping(bytes32 => AtomicTypes.TakerTranche) takerTranches;
        mapping(bytes32 => bytes32) reservationTranche;
        uint256 reservationCounter;
        uint256 trancheCounter;
        uint256 takerTrancheCounter;
        uint256 takerTranchePostingFee;
        address governor;
        uint64 refundSafetyWindow;
        mapping(address => bool) committee;
        address mailbox;
        address atomicDesk;
        bool atomicPaused;
    }

    function atomicStorage() internal pure returns (AtomicStorage storage ds) {
        bytes32 position = ATOMIC_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}

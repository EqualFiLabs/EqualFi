// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AtomicTypes} from "../libraries/AtomicTypes.sol";
import {LibSecp256k1Pubkey} from "../libraries/LibSecp256k1Pubkey.sol";
import {Unauthorized} from "../libraries/Errors.sol";

/// @notice Encrypted per-reservation message board for Atomic Desk swaps.
contract Mailbox {
    struct Messages {
        bytes context;
        bytes presig;
        bytes finalSig;
    }

    error ReservationInactive(bytes32 reservationId);
    error ContextAlreadyPublished(bytes32 reservationId);
    error PreSigAlreadyPublished(bytes32 reservationId);
    error FinalSigAlreadyPublished(bytes32 reservationId);
    error ContextMissing(bytes32 reservationId);
    error PreSigMissing(bytes32 reservationId);
    error InvalidEnvelope();
    error InvalidPubkey();
    error SlotNotAuthorized(bytes32 reservationId);
    error SlotAlreadyAuthorized(bytes32 reservationId);

    event DeskKeyRegistered(address indexed desk, bytes pubkey);
    event ContextPublished(bytes32 indexed reservationId, address indexed taker, bytes envelope);
    event PreSigPublished(bytes32 indexed reservationId, address indexed desk, bytes envelope);
    event FinalSigPublished(bytes32 indexed reservationId, address indexed poster, bytes envelope);
    event ReservationAuthorized(bytes32 indexed reservationId);
    event ReservationRevoked(bytes32 indexed reservationId);

    uint256 public constant MAX_ENVELOPE_BYTES = 4096;

    address public immutable escrow;
    mapping(bytes32 => bool) internal slotAuthorized;

    mapping(bytes32 => Messages) internal reservationMessages;
    mapping(address => bytes) internal deskPubkeys;

    constructor(address escrow_) {
        if (escrow_ == address(0)) revert Unauthorized();
        escrow = escrow_;
    }

    /// @notice Register or update the desk's compressed secp256k1 encryption key.
    function registerPubkey(bytes calldata pubkey) external {
        if (!LibSecp256k1Pubkey.isValidCompressedPubkey(pubkey)) revert InvalidPubkey();
        deskPubkeys[msg.sender] = pubkey;
        emit DeskKeyRegistered(msg.sender, pubkey);
    }

    /// @notice Allow a reservation to begin posting messages. Only callable by escrow.
    function authorizeReservation(bytes32 reservationId) external {
        if (msg.sender != escrow) revert Unauthorized();
        if (slotAuthorized[reservationId]) revert SlotAlreadyAuthorized(reservationId);
        slotAuthorized[reservationId] = true;
        emit ReservationAuthorized(reservationId);
    }

    /// @notice Revoke mailbox access for a reservation. Only callable by escrow.
    function revokeReservation(bytes32 reservationId) external {
        if (msg.sender != escrow) revert Unauthorized();
        if (!slotAuthorized[reservationId]) revert SlotNotAuthorized(reservationId);
        slotAuthorized[reservationId] = false;
        emit ReservationRevoked(reservationId);
    }

    /// @notice Publish an encrypted presig context from the taker to the desk.
    function publishContext(bytes32 reservationId, bytes calldata envelope) external {
        AtomicTypes.Reservation memory reservation = _requireActiveReservation(reservationId);
        if (reservation.taker != msg.sender) revert Unauthorized();

        Messages storage messages = reservationMessages[reservationId];
        if (messages.context.length != 0) revert ContextAlreadyPublished(reservationId);
        _validateEnvelope(envelope);

        messages.context = envelope;
        emit ContextPublished(reservationId, msg.sender, envelope);
    }

    /// @notice Publish the encrypted presignature envelope from the desk to the taker.
    function publishPreSig(bytes32 reservationId, bytes calldata envelope) external {
        AtomicTypes.Reservation memory reservation = _requireActiveReservation(reservationId);
        if (reservation.desk != msg.sender) revert Unauthorized();

        Messages storage messages = reservationMessages[reservationId];
        if (messages.context.length == 0) revert ContextMissing(reservationId);
        if (messages.presig.length != 0) revert PreSigAlreadyPublished(reservationId);
        _validateEnvelope(envelope);

        messages.presig = envelope;
        emit PreSigPublished(reservationId, msg.sender, envelope);
    }

    /// @notice Publish the encrypted final signature envelope from the taker back to the desk.
    function publishFinalSig(bytes32 reservationId, bytes calldata envelope) external {
        AtomicTypes.Reservation memory reservation = _requireActiveReservation(reservationId);
        if (reservation.taker != msg.sender) revert Unauthorized();

        Messages storage messages = reservationMessages[reservationId];
        if (messages.presig.length == 0) revert PreSigMissing(reservationId);
        if (messages.finalSig.length != 0) revert FinalSigAlreadyPublished(reservationId);
        _validateEnvelope(envelope);

        messages.finalSig = envelope;
        emit FinalSigPublished(reservationId, msg.sender, envelope);
    }

    /// @notice Fetch the encrypted messages that have been published for a reservation.
    function fetch(bytes32 reservationId) external view returns (bytes[] memory envelopes) {
        Messages storage messages = reservationMessages[reservationId];

        uint256 count;
        if (messages.context.length != 0) count++;
        if (messages.presig.length != 0) count++;
        if (messages.finalSig.length != 0) count++;

        envelopes = new bytes[](count);
        uint256 idx;
        if (messages.context.length != 0) envelopes[idx++] = messages.context;
        if (messages.presig.length != 0) envelopes[idx++] = messages.presig;
        if (messages.finalSig.length != 0) envelopes[idx++] = messages.finalSig;
    }

    /// @notice Retrieve a desk's registered encryption public key.
    function deskEncryptionPubkey(address desk) external view returns (bytes memory) {
        return deskPubkeys[desk];
    }

    /// @notice View whether a reservation slot is currently authorized for posting.
    function isSlotAuthorized(bytes32 reservationId) external view returns (bool) {
        return slotAuthorized[reservationId];
    }

    function _requireActiveReservation(bytes32 reservationId)
        internal
        view
        returns (AtomicTypes.Reservation memory reservation)
    {
        if (!slotAuthorized[reservationId]) {
            revert SlotNotAuthorized(reservationId);
        }
        reservation = ISettlementEscrow(escrow).getReservation(reservationId);
        if (
            reservation.status != AtomicTypes.ReservationStatus.Active
                || reservation.taker == address(0)
        ) {
            revert ReservationInactive(reservationId);
        }
    }

    function _validateEnvelope(bytes calldata envelope) internal pure {
        uint256 len = envelope.length;
        if (len == 0 || len > MAX_ENVELOPE_BYTES) revert InvalidEnvelope();
    }

}

interface ISettlementEscrow {
    function getReservation(bytes32 reservationId) external view returns (AtomicTypes.Reservation memory);
}

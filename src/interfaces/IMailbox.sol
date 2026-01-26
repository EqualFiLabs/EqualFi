// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IMailbox {
    function authorizeReservation(bytes32 reservationId) external;
    function revokeReservation(bytes32 reservationId) external;
    function isSlotAuthorized(bytes32 reservationId) external view returns (bool);
}

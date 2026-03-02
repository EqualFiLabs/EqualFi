// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IIlmSentinelAdapter {
    function isBorrowAllowed() external view returns (bool);
    function isLiquidationAllowed() external view returns (bool);
}

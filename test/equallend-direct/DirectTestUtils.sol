// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";

library DirectTestUtils {
    /// @dev Mirrors EqualLendDirectFacet._annualizedInterestAmount
    function annualizedInterest(uint256 principal, uint16 aprBps, uint64 durationSeconds) internal pure returns (uint256) {
        if (aprBps == 0 || durationSeconds == 0 || principal == 0) return 0;
        uint256 timeScaledRate = uint256(aprBps) * uint256(durationSeconds);
        return Math.mulDiv(principal, timeScaledRate, (365 days) * 10_000);
    }

    function annualizedInterest(DirectTypes.DirectOfferParams memory params) internal pure returns (uint256) {
        return annualizedInterest(params.principal, params.aprBps, params.durationSeconds);
    }

    function dueTimestamp(uint256 acceptTimestamp, uint64 durationSeconds) internal pure returns (uint64) {
        return uint64(acceptTimestamp + durationSeconds);
    }

    function defaultLenderBps(uint16 feeIndexBps, uint16 protocolBps, uint16 activeBps)
        internal
        pure
        returns (uint16)
    {
        uint256 total = uint256(feeIndexBps) + protocolBps + activeBps;
        if (total >= 10_000) {
            return 0;
        }
        return uint16(10_000 - total);
    }

    function treasurySplitFromLegacy(uint16 lenderBps, uint16 protocolBps) internal pure returns (uint16) {
        if (protocolBps == 0 || lenderBps >= 10_000) return 0;
        uint16 remainder = uint16(10_000 - lenderBps);
        return uint16(Math.mulDiv(protocolBps, 10_000, remainder));
    }

    function activeSplitFromLegacy(uint16 lenderBps, uint16 activeBps) internal pure returns (uint16) {
        if (activeBps == 0 || lenderBps >= 10_000) return 0;
        uint16 remainder = uint16(10_000 - lenderBps);
        return uint16(Math.mulDiv(activeBps, 10_000, remainder));
    }

    function previewSplit(uint256 amount, uint16 treasuryBps, uint16 activeBps, bool treasurySet)
        internal
        pure
        returns (uint256 toTreasury, uint256 toActive, uint256 toFeeIndex)
    {
        if (!treasurySet) treasuryBps = 0;
        toTreasury = Math.mulDiv(amount, treasuryBps, 10_000);
        toActive = Math.mulDiv(amount, activeBps, 10_000);
        toFeeIndex = amount - toTreasury - toActive;
    }
}

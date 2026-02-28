// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {IIlmIsolatedIrmAdapter} from "../interfaces/IIlmIsolatedIrmAdapter.sol";

/// @notice Managed fixed-rate IRM adapter for ILM markets.
contract IlmManagedFixedRateIrm is IIlmIsolatedIrmAdapter {
    uint256 public constant MAX_RATE_PER_SECOND_WAD = 1e15;

    error IlmManagedFixedRateIrmRateTooHigh(uint256 ratePerSecondWad, uint256 maxRatePerSecondWad);

    uint256 public immutable ratePerSecondWad;

    constructor(uint256 ratePerSecondWad_) {
        if (ratePerSecondWad_ > MAX_RATE_PER_SECOND_WAD) {
            revert IlmManagedFixedRateIrmRateTooHigh(ratePerSecondWad_, MAX_RATE_PER_SECOND_WAD);
        }
        ratePerSecondWad = ratePerSecondWad_;
    }

    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external view returns (uint256) {
        return ratePerSecondWad;
    }
}

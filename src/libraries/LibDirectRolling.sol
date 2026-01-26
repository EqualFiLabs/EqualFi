// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DirectTypes} from "./DirectTypes.sol";
import {
    RollingError_InvalidAPY,
    RollingError_InvalidGracePeriod,
    RollingError_InvalidInterval,
    RollingError_InvalidPaymentCount,
    RollingError_ExcessivePremium
} from "./Errors.sol";
import {DirectError_InvalidConfiguration} from "./Errors.sol";

/// @notice Shared validation helpers for rolling-direct loan functionality
library LibDirectRolling {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Validate rolling config bounds and invariants
    function validateRollingConfig(DirectTypes.DirectRollingConfig calldata cfg) internal pure {
        if (cfg.minPaymentIntervalSeconds == 0) revert DirectError_InvalidConfiguration();
        if (cfg.maxPaymentCount == 0) revert DirectError_InvalidConfiguration();
        if (cfg.maxUpfrontPremiumBps > BPS_DENOMINATOR) revert DirectError_InvalidConfiguration();
        if (cfg.minRollingApyBps > cfg.maxRollingApyBps) revert DirectError_InvalidConfiguration();
        if (cfg.maxRollingApyBps > BPS_DENOMINATOR) revert DirectError_InvalidConfiguration();
        if (cfg.defaultPenaltyBps > BPS_DENOMINATOR) revert DirectError_InvalidConfiguration();
        if (cfg.minPaymentBps > BPS_DENOMINATOR) revert DirectError_InvalidConfiguration();
    }

    /// @notice Validate rolling offer parameters against configured bounds
    function validateRollingOfferParams(
        DirectTypes.DirectRollingOfferParams memory params,
        DirectTypes.DirectRollingConfig memory cfg
    ) internal pure {
        if (params.paymentIntervalSeconds < cfg.minPaymentIntervalSeconds) {
            revert RollingError_InvalidInterval(params.paymentIntervalSeconds, cfg.minPaymentIntervalSeconds);
        }
        if (params.maxPaymentCount > cfg.maxPaymentCount) {
            revert RollingError_InvalidPaymentCount(params.maxPaymentCount, cfg.maxPaymentCount);
        }
        if (params.gracePeriodSeconds >= params.paymentIntervalSeconds) {
            revert RollingError_InvalidGracePeriod(params.gracePeriodSeconds, params.paymentIntervalSeconds);
        }
        if (params.rollingApyBps < cfg.minRollingApyBps || params.rollingApyBps > cfg.maxRollingApyBps) {
            revert RollingError_InvalidAPY(params.rollingApyBps, cfg.minRollingApyBps, cfg.maxRollingApyBps);
        }
        if (params.upfrontPremium > (params.principal * cfg.maxUpfrontPremiumBps) / BPS_DENOMINATOR) {
            uint256 maxPremium = (params.principal * cfg.maxUpfrontPremiumBps) / BPS_DENOMINATOR;
            revert RollingError_ExcessivePremium(params.upfrontPremium, maxPremium);
        }
    }
}

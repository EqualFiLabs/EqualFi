// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_InsufficientMargin, Perps_PositionHealthy, Perps_RiskLimitExceeded} from "./PerpsErrors.sol";

/// @notice Margin, health, leverage, and open-interest/skew risk math helpers.
library LibPerpsRisk {
    uint256 internal constant BPS_SCALE = 10_000;

    struct HealthState {
        uint256 collateralValueUsdX18;
        uint256 positionNotionalUsdX18;
        int256 unrealizedPnlUsdX18;
        int256 fundingAccruedUsdX18;
        uint256 feesAccruedUsdX18;
    }

    struct HealthDelta {
        int256 collateralDeltaUsdX18;
        int256 positionNotionalDeltaUsdX18;
        int256 unrealizedPnlDeltaUsdX18;
        int256 fundingAccruedDeltaUsdX18;
        uint256 feeDeltaUsdX18;
    }

    struct HealthResult {
        int256 equityUsdX18;
        uint256 initialMarginRequiredUsdX18;
        uint256 maintenanceMarginRequiredUsdX18;
        uint256 minEquityForLeverageUsdX18;
        uint256 openingMarginRequiredUsdX18;
        uint256 leverageBps;
        int256 initialBufferUsdX18;
        int256 maintenanceBufferUsdX18;
        bool meetsInitialMargin;
        bool meetsMaintenanceMargin;
    }

    struct OpenInterestPreview {
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 openInterestTotal;
        int256 skew;
    }

    function initialMarginRequired(LibPerpsStorage.PerpsMarket memory market, uint256 positionNotionalUsdX18)
        internal
        pure
        returns (uint256)
    {
        return _marginRequired(positionNotionalUsdX18, market.initialMarginBps);
    }

    function maintenanceMarginRequired(LibPerpsStorage.PerpsMarket memory market, uint256 positionNotionalUsdX18)
        internal
        pure
        returns (uint256)
    {
        return _marginRequired(positionNotionalUsdX18, market.maintenanceMarginBps);
    }

    function minEquityForLeverage(LibPerpsStorage.PerpsMarket memory market, uint256 positionNotionalUsdX18)
        internal
        pure
        returns (uint256)
    {
        return _minEquityForLeverage(positionNotionalUsdX18, market.maxLeverageBps);
    }

    function computeHealth(LibPerpsStorage.PerpsMarket memory market, HealthState memory state)
        internal
        pure
        returns (HealthResult memory result)
    {
        result.equityUsdX18 = _equity(state);
        result.initialMarginRequiredUsdX18 = initialMarginRequired(market, state.positionNotionalUsdX18);
        result.maintenanceMarginRequiredUsdX18 = maintenanceMarginRequired(market, state.positionNotionalUsdX18);
        result.minEquityForLeverageUsdX18 = minEquityForLeverage(market, state.positionNotionalUsdX18);
        result.openingMarginRequiredUsdX18 = _max(result.initialMarginRequiredUsdX18, result.minEquityForLeverageUsdX18);

        if (state.positionNotionalUsdX18 == 0) {
            result.leverageBps = 0;
        } else if (result.equityUsdX18 <= 0) {
            result.leverageBps = type(uint256).max;
        } else {
            result.leverageBps = (state.positionNotionalUsdX18 * BPS_SCALE) / uint256(result.equityUsdX18);
        }

        result.initialBufferUsdX18 = result.equityUsdX18 - _toInt(result.openingMarginRequiredUsdX18);
        result.maintenanceBufferUsdX18 = result.equityUsdX18 - _toInt(result.maintenanceMarginRequiredUsdX18);
        result.meetsInitialMargin = result.initialBufferUsdX18 >= 0;
        result.meetsMaintenanceMargin = result.maintenanceBufferUsdX18 >= 0;
    }

    function previewHealth(
        LibPerpsStorage.PerpsMarket memory market,
        HealthState memory state,
        HealthDelta memory delta
    ) internal pure returns (HealthResult memory result, HealthState memory postState) {
        postState = state;
        postState.collateralValueUsdX18 = _applySignedDelta(postState.collateralValueUsdX18, delta.collateralDeltaUsdX18);
        postState.positionNotionalUsdX18 = _applySignedDelta(postState.positionNotionalUsdX18, delta.positionNotionalDeltaUsdX18);
        postState.unrealizedPnlUsdX18 = _checkedAddInt(postState.unrealizedPnlUsdX18, delta.unrealizedPnlDeltaUsdX18);
        postState.fundingAccruedUsdX18 = _checkedAddInt(postState.fundingAccruedUsdX18, delta.fundingAccruedDeltaUsdX18);
        postState.feesAccruedUsdX18 += delta.feeDeltaUsdX18;

        result = computeHealth(market, postState);
    }

    function enforceOpenRisk(LibPerpsStorage.PerpsMarket memory market, HealthState memory state)
        internal
        pure
        returns (HealthResult memory result)
    {
        result = computeHealth(market, state);
        if (!result.meetsInitialMargin) {
            revert Perps_InsufficientMargin(result.openingMarginRequiredUsdX18, _positiveEquityFloor(result.equityUsdX18));
        }
    }

    function enforceMaintenanceMargin(LibPerpsStorage.PerpsMarket memory market, HealthState memory state)
        internal
        pure
        returns (HealthResult memory result)
    {
        result = computeHealth(market, state);
        if (!result.meetsMaintenanceMargin) {
            revert Perps_InsufficientMargin(result.maintenanceMarginRequiredUsdX18, _positiveEquityFloor(result.equityUsdX18));
        }
    }

    function enforceLiquidatable(LibPerpsStorage.PerpsMarket memory market, HealthState memory state)
        internal
        pure
        returns (HealthResult memory result)
    {
        result = computeHealth(market, state);
        if (result.meetsMaintenanceMargin) {
            revert Perps_PositionHealthy();
        }
    }

    function previewOpenInterestAfterDelta(
        LibPerpsStorage.PerpsMarket memory market,
        LibPerpsStorage.PerpsMarketState memory state,
        bool isLong,
        int256 sizeDeltaUsdX18
    ) internal pure returns (OpenInterestPreview memory preview) {
        preview.openInterestLong = state.openInterestLong;
        preview.openInterestShort = state.openInterestShort;

        if (sizeDeltaUsdX18 >= 0) {
            uint256 increase = uint256(sizeDeltaUsdX18);
            if (isLong) {
                preview.openInterestLong += increase;
            } else {
                preview.openInterestShort += increase;
            }
        } else {
            uint256 decrease = _negativeMagnitude(sizeDeltaUsdX18);
            if (isLong) {
                if (decrease > preview.openInterestLong) revert Perps_RiskLimitExceeded();
                preview.openInterestLong -= decrease;
            } else {
                if (decrease > preview.openInterestShort) revert Perps_RiskLimitExceeded();
                preview.openInterestShort -= decrease;
            }
        }

        preview.openInterestTotal = preview.openInterestLong + preview.openInterestShort;
        preview.skew = _toInt(preview.openInterestLong) - _toInt(preview.openInterestShort);

        enforceOpenInterestAndSkewCaps(market, preview);
    }

    function enforceOpenInterestAndSkewCaps(LibPerpsStorage.PerpsMarket memory market, OpenInterestPreview memory preview)
        internal
        pure
    {
        if (market.maxOpenInterest != 0 && preview.openInterestTotal > market.maxOpenInterest) {
            revert Perps_RiskLimitExceeded();
        }
        if (market.maxLongOpenInterest != 0 && preview.openInterestLong > market.maxLongOpenInterest) {
            revert Perps_RiskLimitExceeded();
        }
        if (market.maxShortOpenInterest != 0 && preview.openInterestShort > market.maxShortOpenInterest) {
            revert Perps_RiskLimitExceeded();
        }
        if (market.maxSkewAbs != 0 && _abs(preview.skew) > market.maxSkewAbs) {
            revert Perps_RiskLimitExceeded();
        }
    }

    function _marginRequired(uint256 positionNotionalUsdX18, uint32 marginBps) private pure returns (uint256) {
        return (positionNotionalUsdX18 * uint256(marginBps)) / BPS_SCALE;
    }

    function _minEquityForLeverage(uint256 positionNotionalUsdX18, uint32 maxLeverageBps) private pure returns (uint256) {
        if (positionNotionalUsdX18 == 0) return 0;
        if (maxLeverageBps == 0) revert Perps_RiskLimitExceeded();
        return _ceilDiv(positionNotionalUsdX18 * BPS_SCALE, uint256(maxLeverageBps));
    }

    function _equity(HealthState memory state) private pure returns (int256) {
        return _toInt(state.collateralValueUsdX18) + state.unrealizedPnlUsdX18 - _toInt(state.feesAccruedUsdX18)
            - state.fundingAccruedUsdX18;
    }

    function _positiveEquityFloor(int256 equityUsdX18) private pure returns (uint256) {
        if (equityUsdX18 <= 0) return 0;
        return uint256(equityUsdX18);
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a : b;
    }

    function _abs(int256 value) private pure returns (uint256) {
        if (value >= 0) return uint256(value);
        if (value == type(int256).min) revert Perps_RiskLimitExceeded();
        return uint256(-value);
    }

    function _toInt(uint256 value) private pure returns (int256) {
        if (value > uint256(type(int256).max)) revert Perps_RiskLimitExceeded();
        return int256(value);
    }

    function _checkedAddInt(int256 a, int256 b) private pure returns (int256 c) {
        c = a + b;
        if ((b > 0 && c < a) || (b < 0 && c > a)) {
            revert Perps_RiskLimitExceeded();
        }
    }

    function _negativeMagnitude(int256 value) private pure returns (uint256) {
        if (value >= 0) return uint256(value);
        if (value == type(int256).min) revert Perps_RiskLimitExceeded();
        return uint256(-value);
    }

    function _applySignedDelta(uint256 value, int256 delta) private pure returns (uint256 updated) {
        if (delta >= 0) {
            updated = value + uint256(delta);
        } else {
            uint256 decrease = _negativeMagnitude(delta);
            if (decrease > value) revert Perps_RiskLimitExceeded();
            updated = value - decrease;
        }
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        if (denominator == 0) revert Perps_RiskLimitExceeded();
        if (numerator == 0) return 0;
        return ((numerator - 1) / denominator) + 1;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {IIlmIsolatedIrmAdapter} from "../interfaces/IIlmIsolatedIrmAdapter.sol";

/// @notice Adaptive-curve IRM modeled after Morpho Blue's adaptive curve behavior.
/// @dev Stateful: updates per-market `rateAtTarget` on each borrow-rate read from authorized protocol caller.
contract IlmAdaptiveCurveIrm is IIlmIsolatedIrmAdapter {
    int256 internal constant WAD_INT = 1e18;

    int256 public constant CURVE_STEEPNESS = 4 ether;
    int256 public constant ADJUSTMENT_SPEED = 50 ether / int256(365 days);
    int256 public constant TARGET_UTILIZATION = 0.9 ether;
    int256 public constant INITIAL_RATE_AT_TARGET = 0.04 ether / int256(365 days);
    int256 public constant MIN_RATE_AT_TARGET = 0.001 ether / int256(365 days);
    int256 public constant MAX_RATE_AT_TARGET = 2 ether / int256(365 days);

    int256 internal constant LN_2_INT = 0.693147180559945309 ether;
    int256 internal constant LN_WEI_INT = -41.446531673892822312 ether;
    int256 internal constant WEXP_UPPER_BOUND = 93.859467695000404319 ether;
    int256 internal constant WEXP_UPPER_VALUE = 57716089161558943949701069502944508345128.422502756744429568 ether;

    error IlmAdaptiveCurveIrmUnauthorized(address caller);
    error IlmAdaptiveCurveIrmZeroAddress();

    event IlmAdaptiveCurveIrmBorrowRateUpdate(bytes32 indexed marketId, uint256 avgBorrowRate, int256 rateAtTarget);

    /// @notice The only caller allowed to update the adaptive per-market state.
    address public immutable protocolCaller;

    /// @notice Per-market adaptive rate-at-target state (WAD per second).
    mapping(bytes32 => int256) public rateAtTarget;

    constructor(address protocolCaller_) {
        if (protocolCaller_ == address(0)) {
            revert IlmAdaptiveCurveIrmZeroAddress();
        }
        protocolCaller = protocolCaller_;
    }

    /// @inheritdoc IIlmIsolatedIrmAdapter
    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata params,
        IlmIsolatedTypes.IlmIsolatedMarket calldata market
    ) external returns (uint256 ratePerSecond) {
        if (msg.sender != protocolCaller) {
            revert IlmAdaptiveCurveIrmUnauthorized(msg.sender);
        }

        bytes32 marketId = keccak256(abi.encode(params));
        int256 endRateAtTarget;
        (ratePerSecond, endRateAtTarget) = _borrowRate(marketId, market);
        rateAtTarget[marketId] = endRateAtTarget;

        emit IlmAdaptiveCurveIrmBorrowRateUpdate(marketId, ratePerSecond, endRateAtTarget);
    }

    function _borrowRate(bytes32 marketId, IlmIsolatedTypes.IlmIsolatedMarket calldata market)
        internal
        view
        returns (uint256, int256)
    {
        int256 utilization = 0;
        if (market.totalSupplyAssets > 0) {
            utilization = int256(_wDivDown(market.totalBorrowAssets, market.totalSupplyAssets));
        }

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = _wDivToZero(utilization - TARGET_UTILIZATION, errNormFactor);

        int256 startRateAtTarget = rateAtTarget[marketId];
        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            int256 speed = _wMulToZero(ADJUSTMENT_SPEED, err);
            int256 elapsed = int256(block.timestamp - uint256(market.lastUpdate));
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        int256 avgRate = _curve(avgRateAtTarget, err);
        return (uint256(avgRate), endRateAtTarget);
    }

    function _curve(int256 _rateAtTarget, int256 err) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD_INT - _wDivToZero(WAD_INT, CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD_INT;
        return _wMulToZero(_wMulToZero(coeff, err) + WAD_INT, _rateAtTarget);
    }

    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) internal pure returns (int256) {
        int256 updated = _wMulToZero(startRateAtTarget, _wExp(linearAdaptation));
        return _bound(updated, MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }

    function _wMulToZero(int256 x, int256 y) internal pure returns (int256) {
        return (x * y) / WAD_INT;
    }

    function _wDivToZero(int256 x, int256 y) internal pure returns (int256) {
        return (x * WAD_INT) / y;
    }

    function _wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * uint256(WAD_INT) / y;
    }

    function _bound(int256 x, int256 low, int256 high) internal pure returns (int256) {
        if (x < low) {
            return low;
        }
        if (x > high) {
            return high;
        }
        return x;
    }

    function _wExp(int256 x) internal pure returns (int256) {
        unchecked {
            if (x < LN_WEI_INT) {
                return 0;
            }
            if (x >= WEXP_UPPER_BOUND) {
                return WEXP_UPPER_VALUE;
            }

            int256 roundingAdjustment = x < 0 ? -(LN_2_INT / 2) : (LN_2_INT / 2);
            int256 q = (x + roundingAdjustment) / LN_2_INT;
            int256 r = x - q * LN_2_INT;

            int256 expR = WAD_INT + r + (r * r) / WAD_INT / 2;
            if (q >= 0) {
                return expR << uint256(q);
            }
            return expR >> uint256(-q);
        }
    }
}

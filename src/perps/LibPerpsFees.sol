// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {Types} from "../libraries/Types.sol";
import {LibPerpsDomain} from "./LibPerpsDomain.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_RiskLimitExceeded} from "./PerpsErrors.sol";

/// @notice Perps fee split and routing helpers.
library LibPerpsFees {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant INDEX_SCALE = 1e18;
    uint256 internal constant LP_SHARE_BPS = 7_000;
    uint256 internal constant PROTOCOL_SHARE_BPS = 3_000;
    bytes32 internal constant DEFAULT_PERPS_FEE_SOURCE = keccak256("equalis.perps.fee.v1");

    struct FeeSplit {
        uint256 totalFee;
        uint256 lpFee;
        uint256 protocolFee;
        uint256 executorFee;
    }

    function previewTradingFeeSplit(uint256 totalFee) internal pure returns (FeeSplit memory split) {
        if (totalFee == 0) return split;

        split.totalFee = totalFee;
        split.lpFee = (totalFee * LP_SHARE_BPS) / BPS_DENOMINATOR;
        split.protocolFee = totalFee - split.lpFee;
    }

    function applyTradingFee(
        bytes32 marketId,
        uint256 totalFee,
        uint256 feePoolId,
        bytes32 feeSource
    ) internal returns (FeeSplit memory split, uint256 explicitOutboundCredit) {
        split = previewTradingFeeSplit(totalFee);
        if (split.totalFee == 0) return (split, 0);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[marketId];

        if (split.lpFee > 0) {
            uint256 distributable = split.lpFee + ps.marketPendingLpFees[marketId];
            uint256 totalLpShares = state.reservedCollateral;
            if (totalLpShares == 0) {
                ps.marketPendingLpFees[marketId] = distributable;
            } else {
                uint256 deltaIndex = Math.mulDiv(distributable, INDEX_SCALE, totalLpShares);
                if (deltaIndex == 0) {
                    ps.marketPendingLpFees[marketId] = distributable;
                } else {
                    uint256 distributed = Math.mulDiv(deltaIndex, totalLpShares, INDEX_SCALE);
                    state.lpFeeIndexX18 += deltaIndex;
                    ps.marketPendingLpFees[marketId] = distributable - distributed;
                }
            }
        }

        if (split.protocolFee > 0) {
            if (feePoolId == 0) revert Perps_RiskLimitExceeded();
            state.protocolFeesAccrued += split.protocolFee;
            explicitOutboundCredit =
                _routeProtocolFeeToGlobalRails(feePoolId, split.protocolFee, feeSource == bytes32(0) ? DEFAULT_PERPS_FEE_SOURCE : feeSource);
        }
    }

    function settleAccountLpFees(bytes32 marketId, bytes32 accountId)
        internal
        returns (uint256 newlyAccrued, uint256 totalAccrued)
    {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        uint256 globalIndex = ps.marketState[marketId].lpFeeIndexX18;
        uint256 accountIndex = ps.accountLpFeeIndexX18[accountId][marketId];
        uint256 collateralShares = ps.accountCollateral[accountId][marketId];

        if (globalIndex > accountIndex && collateralShares > 0) {
            newlyAccrued = Math.mulDiv(collateralShares, globalIndex - accountIndex, INDEX_SCALE);
            if (newlyAccrued > 0) {
                ps.accountLpFeesAccrued[accountId][marketId] += newlyAccrued;
            }
        }

        ps.accountLpFeeIndexX18[accountId][marketId] = globalIndex;
        totalAccrued = ps.accountLpFeesAccrued[accountId][marketId];
    }

    function claimAccountLpFees(bytes32 marketId, bytes32 accountId) internal returns (uint256 claimed) {
        (, claimed) = settleAccountLpFees(marketId, accountId);
        if (claimed == 0) {
            return 0;
        }

        LibPerpsStorage.s().accountLpFeesAccrued[accountId][marketId] = 0;
        LibPerpsDomain.debitIsolatedTracked(claimed);
    }

    function previewAccountLpFees(bytes32 marketId, bytes32 accountId)
        internal
        view
        returns (uint256 accrued, uint256 pending, uint256 total)
    {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        accrued = ps.accountLpFeesAccrued[accountId][marketId];

        uint256 globalIndex = ps.marketState[marketId].lpFeeIndexX18;
        uint256 accountIndex = ps.accountLpFeeIndexX18[accountId][marketId];
        uint256 collateralShares = ps.accountCollateral[accountId][marketId];
        if (globalIndex > accountIndex && collateralShares > 0) {
            pending = Math.mulDiv(collateralShares, globalIndex - accountIndex, INDEX_SCALE);
        }

        total = accrued + pending;
    }

    function applyExecutorFee(uint256 requestedExecutorFee, uint256 signerApprovedMaxExecutorFee)
        internal
        returns (uint256 chargedExecutorFee)
    {
        if (requestedExecutorFee > signerApprovedMaxExecutorFee) {
            revert Perps_RiskLimitExceeded();
        }
        if (requestedExecutorFee == 0) return 0;

        // Executor rewards are paid from isolated perps domain balances only.
        LibPerpsDomain.debitIsolatedTracked(requestedExecutorFee);
        chargedExecutorFee = requestedExecutorFee;
    }

    function _routeProtocolFeeToGlobalRails(uint256 feePoolId, uint256 protocolFee, bytes32 feeSource)
        private
        returns (uint256 explicitOutboundCredit)
    {
        explicitOutboundCredit = LibPerpsDomain.routeOutboundFeeCredit(protocolFee);
        _creditNonPerpsFeePoolFromPerpsDomain(feePoolId, explicitOutboundCredit);

        // Route via canonical global fee rails (treasury/ACI/FI) without debiting tracked
        // during this perps operation to preserve explicit credit-only non-perps deltas.
        LibFeeRouter.routeManagedShare(feePoolId, explicitOutboundCredit, feeSource, false, 0);
    }

    function _creditNonPerpsFeePoolFromPerpsDomain(uint256 feePoolId, uint256 amount) private {
        if (amount == 0) return;

        Types.PoolData storage feePool = LibAppStorage.s().pools[feePoolId];
        feePool.trackedBalance += amount;
        if (LibCurrency.isNative(feePool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal += amount;
        }
    }
}

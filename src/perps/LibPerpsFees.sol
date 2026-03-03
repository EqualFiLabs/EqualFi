// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

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
            state.lpFeeIndexX18 += split.lpFee;
        }

        if (split.protocolFee > 0) {
            if (feePoolId == 0) revert Perps_RiskLimitExceeded();
            state.protocolFeesAccrued += split.protocolFee;
            explicitOutboundCredit =
                _routeProtocolFeeToGlobalRails(feePoolId, split.protocolFee, feeSource == bytes32(0) ? DEFAULT_PERPS_FEE_SOURCE : feeSource);
        }
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

        // Route via canonical global fee rails (treasury/ACI/FI) from credited pool tracked backing.
        LibFeeRouter.routeManagedShare(feePoolId, explicitOutboundCredit, feeSource, true, 0);
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

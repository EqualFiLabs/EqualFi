// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DerivativeTypes} from "./DerivativeTypes.sol";

library LibDerivativeFees {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    error DerivativeFeeOutOfBounds(uint16 feeBps, uint16 maxBps);
    error DerivativeFeeCapOutOfBounds(uint16 maxTotalFeeBps);
    error DerivativeDefaultFeeOutOfBounds(uint16 defaultFeeBps, uint16 maxFeeBps);
    error DerivativeFlatFeeOutOfBounds(uint128 flatFee, uint128 maxFlatFee);
    error DerivativeFeeExceedsCap(uint256 feeAmount, uint256 capAmount, uint16 capBps);
    error DerivativeFeeExceedsPayment(uint256 feeAmount, uint256 paymentAmount);

    function validateActionFeeConfig(DerivativeTypes.DerivativeActionFeeConfig memory config) internal pure {
        uint16 maxFeeBps = config.maxFeeBps;
        if (maxFeeBps > BPS_DENOMINATOR) {
            revert DerivativeFeeOutOfBounds(maxFeeBps, BPS_DENOMINATOR);
        }
        if (config.defaultFeeBps > maxFeeBps) {
            revert DerivativeDefaultFeeOutOfBounds(config.defaultFeeBps, maxFeeBps);
        }
        uint16 maxTotalFeeBps = config.maxTotalFeeBps;
        if (maxTotalFeeBps > BPS_DENOMINATOR) {
            revert DerivativeFeeCapOutOfBounds(maxTotalFeeBps);
        }
        if (config.defaultFlatFee > config.maxFlatFee) {
            revert DerivativeFlatFeeOutOfBounds(config.defaultFlatFee, config.maxFlatFee);
        }
    }

    function validateFeeBps(uint16 feeBps, uint16 maxBps) internal pure {
        if (feeBps > maxBps) {
            revert DerivativeFeeOutOfBounds(feeBps, maxBps);
        }
    }

    function computeFeeAmount(
        uint256 baseAmount,
        uint16 feeBps,
        uint128 flatFee,
        uint16 maxTotalFeeBps
    ) internal pure returns (uint256 feeAmount) {
        uint256 bpsFee = (baseAmount * feeBps) / BPS_DENOMINATOR;
        feeAmount = bpsFee + uint256(flatFee);
        uint256 capAmount = (baseAmount * maxTotalFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > capAmount) {
            revert DerivativeFeeExceedsCap(feeAmount, capAmount, maxTotalFeeBps);
        }
    }

    function enforceFeeWithinPayment(uint256 feeAmount, uint256 paymentAmount) internal pure {
        if (feeAmount > paymentAmount) {
            revert DerivativeFeeExceedsPayment(feeAmount, paymentAmount);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LibDerivativeFees {
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant WAD = 1e18;

    error DerivativeFeeOutOfBounds(uint16 feeBps, uint16 minBps, uint16 maxBps);
    error DerivativeFeeExceedsPayment(uint256 feeAmount, uint256 paymentAmount);

    function validateFeeBps(uint16 feeBps, uint16 minBps, uint16 maxBps) internal pure {
        if (feeBps < minBps || feeBps > maxBps) {
            revert DerivativeFeeOutOfBounds(feeBps, minBps, maxBps);
        }
    }

    function computeFeeAmount(
        uint256 baseAmount,
        uint16 feeBps,
        uint128 flatFeeWad,
        address feeToken
    ) internal view returns (uint256 feeAmount) {
        if (baseAmount == 0) {
            return 0;
        }
        uint256 bpsFee = (baseAmount * feeBps) / BPS_DENOMINATOR;
        uint256 flatFee = _flatFeeAmount(flatFeeWad, feeToken);
        feeAmount = bpsFee + flatFee;
    }

    function enforceFeeWithinPayment(uint256 feeAmount, uint256 paymentAmount) internal pure {
        if (feeAmount > paymentAmount) {
            revert DerivativeFeeExceedsPayment(feeAmount, paymentAmount);
        }
    }

    function _flatFeeAmount(uint128 flatFeeWad, address feeToken) private view returns (uint256) {
        if (flatFeeWad == 0) {
            return 0;
        }
        uint8 decimals = IERC20Metadata(feeToken).decimals();
        return Math.mulDiv(uint256(flatFeeWad), 10 ** uint256(decimals), WAD);
    }
}

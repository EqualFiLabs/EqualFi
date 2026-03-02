// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmLiquidation} from "../../src/ilm-pooled/libraries/LibIlmLiquidation.sol";

contract LibIlmLiquidationHarness {
    function computeHealthFactor(
        uint256 collateralAmount,
        uint256 oraclePriceRay,
        uint16 liquidationThresholdBps,
        uint256 debtValue
    ) external pure returns (uint256) {
        return LibIlmLiquidation.computeHealthFactor(collateralAmount, oraclePriceRay, liquidationThresholdBps, debtValue);
    }

    function determineCloseFactor(uint256 hf) external pure returns (uint16) {
        return LibIlmLiquidation.determineCloseFactor(hf);
    }

    function computeLiquidationAmounts(
        uint256 actualDebtToLiquidate,
        uint256 oraclePriceRay,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) external pure returns (uint256, uint256, uint256) {
        return LibIlmLiquidation.computeLiquidationAmounts(
            actualDebtToLiquidate, oraclePriceRay, liquidationBonusBps, liquidationProtocolFeeBps
        );
    }
}

contract LibIlmLiquidationPropertyTest is Test {
    LibIlmLiquidationHarness internal h;

    function setUp() public {
        h = new LibIlmLiquidationHarness();
    }

    /// @dev Property 16: Health Factor Formula Correctness
    /// Validates: Requirements 8.1
    function testFuzz_property16_healthFactorFormulaCorrectness(
        uint256 collateralRaw,
        uint256 priceRaw,
        uint256 thresholdRaw,
        uint256 debtRaw
    ) public {
        uint256 collateralAmount = bound(collateralRaw, 0, 1e30);
        uint256 oraclePriceRay = bound(priceRaw, 1, 1e36);
        uint256 liquidationThresholdBps = bound(thresholdRaw, 0, IlmTypes.BPS);
        uint256 debtValue = bound(debtRaw, 0, 1e30);

        uint256 hf = h.computeHealthFactor(collateralAmount, oraclePriceRay, uint16(liquidationThresholdBps), debtValue);

        if (debtValue == 0) {
            assertEq(hf, type(uint256).max);
            return;
        }

        uint256 collateralValue = Math.mulDiv(collateralAmount, oraclePriceRay, IlmTypes.RAY);
        uint256 thresholdValue = Math.mulDiv(collateralValue, liquidationThresholdBps, IlmTypes.BPS);
        uint256 expected = Math.mulDiv(thresholdValue, IlmTypes.HF_PRECISION, debtValue);
        assertEq(hf, expected);
    }

    /// @dev Property 18: Close Factor Determination
    /// Validates: Requirements 9.3, 9.4
    function testFuzz_property18_closeFactorDetermination(uint256 hfRaw) public {
        uint256 hf = bound(hfRaw, 0, 3e18);
        uint16 closeFactor = h.determineCloseFactor(hf);
        uint16 expected = hf < IlmTypes.CLOSE_FACTOR_HF_THRESHOLD ? uint16(IlmTypes.BPS) : IlmTypes.DEFAULT_CLOSE_FACTOR_BPS;
        assertEq(closeFactor, expected);
    }

    /// @dev Property 19: Liquidation Amount Computation
    /// Validates: Requirements 9.5, 9.6
    function testFuzz_property19_liquidationAmountComputation(
        uint256 debtRaw,
        uint256 priceRaw,
        uint256 bonusBpsRaw,
        uint256 feeBpsRaw
    ) public {
        uint256 actualDebtToLiquidate = bound(debtRaw, 0, 1e30);
        uint256 oraclePriceRay = bound(priceRaw, 1, 1e36);
        uint256 liquidationBonusBps = bound(bonusBpsRaw, 0, 5_000);
        uint256 liquidationProtocolFeeBps = bound(feeBpsRaw, 0, IlmTypes.BPS);

        (uint256 grossSeized, uint256 protocolFee, uint256 netSeized) = h.computeLiquidationAmounts(
            actualDebtToLiquidate,
            oraclePriceRay,
            uint16(liquidationBonusBps),
            uint16(liquidationProtocolFeeBps)
        );

        uint256 seizedValueInLoanAsset = Math.mulDiv(
            actualDebtToLiquidate,
            IlmTypes.BPS + liquidationBonusBps,
            IlmTypes.BPS
        );
        uint256 expectedGross = Math.mulDiv(seizedValueInLoanAsset, IlmTypes.RAY, oraclePriceRay);
        uint256 expectedProtocolFee = Math.mulDiv(expectedGross, liquidationProtocolFeeBps, IlmTypes.BPS);
        uint256 expectedNet = expectedGross - expectedProtocolFee;

        assertEq(grossSeized, expectedGross);
        assertEq(protocolFee, expectedProtocolFee);
        assertEq(netSeized, expectedNet);
        assertEq(netSeized + protocolFee, grossSeized);
    }
}

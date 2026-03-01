// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes} from "../../src/libraries/IlmTypes.sol";
import {LibIlmInterestRate} from "../../src/libraries/LibIlmInterestRate.sol";

contract LibIlmInterestRateHarness {
    function computeVariableBorrowRate(
        uint256 utilizationRay,
        uint256 optimalUtilizationRay,
        uint256 baseVariableRateRay,
        uint256 slope1Ray,
        uint256 slope2Ray
    ) external pure returns (uint256) {
        return LibIlmInterestRate.computeVariableBorrowRate(
            utilizationRay, optimalUtilizationRay, baseVariableRateRay, slope1Ray, slope2Ray
        );
    }

    function computeLiquidityRate(uint256 variableBorrowRateRay, uint256 utilizationRay, uint256 reserveFactorBps)
        external
        pure
        returns (uint256)
    {
        return LibIlmInterestRate.computeLiquidityRate(variableBorrowRateRay, utilizationRay, reserveFactorBps);
    }
}

contract LibIlmInterestRatePropertyTest is Test {
    LibIlmInterestRateHarness internal h;

    function setUp() public {
        h = new LibIlmInterestRateHarness();
    }

    /// @dev Property 13: Kinked Rate Model Correctness
    /// Validates: Requirements 7.2, 7.3, 7.4
    function testFuzz_property13_kinkedRateModelCorrectness(
        uint256 utilizationRaw,
        uint256 optimalRaw,
        uint256 baseRaw,
        uint256 slope1Raw,
        uint256 slope2Raw,
        uint256 reserveFactorRaw
    ) public {
        uint256 utilizationRay = bound(utilizationRaw, 0, IlmTypes.RAY);
        uint256 optimalUtilizationRay = bound(optimalRaw, 1, IlmTypes.RAY - 1);
        uint256 baseVariableRateRay = bound(baseRaw, 0, 2e27);
        uint256 slope1Ray = bound(slope1Raw, 0, 2e27);
        uint256 slope2Ray = bound(slope2Raw, 0, 2e27);
        uint256 reserveFactorBps = bound(reserveFactorRaw, 0, IlmTypes.BPS);

        uint256 expectedVariableBorrowRate;
        if (utilizationRay <= optimalUtilizationRay) {
            expectedVariableBorrowRate =
                baseVariableRateRay + Math.mulDiv(slope1Ray, utilizationRay, optimalUtilizationRay);
        } else {
            expectedVariableBorrowRate = baseVariableRateRay + slope1Ray
                + Math.mulDiv(slope2Ray, utilizationRay - optimalUtilizationRay, IlmTypes.RAY - optimalUtilizationRay);
        }

        uint256 reserveFactorRay = Math.mulDiv(reserveFactorBps, IlmTypes.RAY, IlmTypes.BPS);
        uint256 expectedLiquidityRate = Math.mulDiv(
            Math.mulDiv(expectedVariableBorrowRate, utilizationRay, IlmTypes.RAY),
            IlmTypes.RAY - reserveFactorRay,
            IlmTypes.RAY
        );

        uint256 variableBorrowRate = h.computeVariableBorrowRate(
            utilizationRay, optimalUtilizationRay, baseVariableRateRay, slope1Ray, slope2Ray
        );
        uint256 liquidityRate = h.computeLiquidityRate(variableBorrowRate, utilizationRay, reserveFactorBps);

        assertEq(variableBorrowRate, expectedVariableBorrowRate);
        assertEq(liquidityRate, expectedLiquidityRate);
    }

    function testFuzz_computeFunctions_capInputs(uint256 utilizationRaw, uint256 reserveFactorRaw) public {
        uint256 utilizationRay = IlmTypes.RAY + bound(utilizationRaw, 1, 1e27);
        uint256 reserveFactorBps = IlmTypes.BPS + bound(reserveFactorRaw, 1, 10_000);

        uint256 variableBorrowRate = h.computeVariableBorrowRate(utilizationRay, 8e26, 1e26, 1e26, 2e26);
        uint256 liquidityRate = h.computeLiquidityRate(variableBorrowRate, utilizationRay, reserveFactorBps);

        uint256 expectedVariableBorrowRate = h.computeVariableBorrowRate(IlmTypes.RAY, 8e26, 1e26, 1e26, 2e26);
        uint256 expectedLiquidityRate = h.computeLiquidityRate(expectedVariableBorrowRate, IlmTypes.RAY, IlmTypes.BPS);

        assertEq(variableBorrowRate, expectedVariableBorrowRate);
        assertEq(liquidityRate, expectedLiquidityRate);
    }
}

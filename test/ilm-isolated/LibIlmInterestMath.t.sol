// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmInterestMath} from "../../src/ilm-isolated/libraries/LibIlmInterestMath.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";

contract MockIlmIsolatedIrmAdapter is IIlmIsolatedIrmAdapter {
    uint256 internal _ratePerSecond;

    function setRate(uint256 ratePerSecond) external {
        _ratePerSecond = ratePerSecond;
    }

    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external view returns (uint256 ratePerSecond) {
        return _ratePerSecond;
    }
}

contract LibIlmInterestMathHarness {
    IlmIsolatedTypes.IlmIsolatedMarketParams internal _params;
    IlmIsolatedTypes.IlmIsolatedMarket internal _market;

    function setParams(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params_) external {
        _params = params_;
    }

    function setMarket(IlmIsolatedTypes.IlmIsolatedMarket calldata market_) external {
        _market = market_;
    }

    function getMarket() external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return _market;
    }

    function accrue(uint256 fee) external returns (uint256 interest, uint256 protocolFeeAccrued) {
        return LibIlmInterestMath.accrueInterest(_market, _params, fee);
    }

    function wTaylorCompounded(uint256 ratePerSecond, uint256 elapsedSeconds) external pure returns (uint256) {
        return LibIlmInterestMath.wTaylorCompounded(ratePerSecond, elapsedSeconds);
    }
}

contract LibIlmInterestMathTest is Test {
    uint256 internal constant WAD = 1e18;

    LibIlmInterestMathHarness internal h;
    MockIlmIsolatedIrmAdapter internal irm;

    function setUp() public {
        vm.warp(10_000_000);
        h = new LibIlmInterestMathHarness();
        irm = new MockIlmIsolatedIrmAdapter();
    }

    /// @dev Property 19: Taylor Compounded Approximation
    /// Validates: Requirements 12.3
    function testFuzz_property19_taylorCompoundedApproximation(
        uint256 ratePerSecondRaw,
        uint256 elapsedRaw,
        uint256 rateDeltaRaw,
        uint256 elapsedDeltaRaw
    ) public {
        uint256 ratePerSecond = _clamp(ratePerSecondRaw, 0, 1e15);
        uint256 elapsed = _clamp(elapsedRaw, 0, 365 days);

        uint256 x = ratePerSecond * elapsed;
        uint256 expected = x + ((x * x / WAD) / 2) + (((x * x / WAD) * x / WAD) / 6);
        uint256 actual = h.wTaylorCompounded(ratePerSecond, elapsed);
        assertEq(actual, expected);

        uint256 biggerRate = ratePerSecond + _clamp(rateDeltaRaw, 0, 1e15);
        uint256 biggerElapsed = elapsed + _clamp(elapsedDeltaRaw, 0, 365 days);

        uint256 atBiggerRate = h.wTaylorCompounded(biggerRate, elapsed);
        uint256 atBiggerElapsed = h.wTaylorCompounded(ratePerSecond, biggerElapsed);
        assertGe(atBiggerRate, actual);
        assertGe(atBiggerElapsed, actual);

        if (elapsed == 0) {
            assertEq(actual, 0);
        }
    }

    /// @dev Property 20: Interest Accrual State Consistency
    /// Validates: Requirements 12.4, 12.5, 12.6, 12.7
    function testFuzz_property20_interestAccrualStateConsistency(
        uint128 totalBorrowAssetsRaw,
        uint128 totalSupplyAssetsRaw,
        uint128 totalSupplySharesRaw,
        uint64 ratePerSecondRaw,
        uint32 elapsedRaw,
        uint64 feeRaw
    ) public {
        uint256 totalBorrowAssets = _clamp(uint256(totalBorrowAssetsRaw), 1, 1e18);
        uint256 totalSupplyAssets = totalBorrowAssets + _clamp(uint256(totalSupplyAssetsRaw), 0, 1e18);
        uint256 totalSupplyShares = _clamp(uint256(totalSupplySharesRaw), 0, 1e18);
        uint256 ratePerSecond = _clamp(uint256(ratePerSecondRaw), 0, 1e12);
        uint256 elapsed = _clamp(uint256(elapsedRaw), 1, 30 days);
        uint256 fee = _clamp(uint256(feeRaw), 0, IlmIsolatedTypes.MAX_FEE);

        uint256 factor = h.wTaylorCompounded(ratePerSecond, elapsed);
        uint256 grossInterestExpected = totalBorrowAssets * factor / WAD;
        uint256 protocolFeeExpected = grossInterestExpected * fee / WAD;
        uint256 newBorrowExpected = totalBorrowAssets + grossInterestExpected;
        uint256 newSupplyExpected = totalSupplyAssets + grossInterestExpected - protocolFeeExpected;
        vm.assume(newBorrowExpected <= type(uint128).max);
        vm.assume(newSupplyExpected <= type(uint128).max);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 1,
            collateralPoolId: 2,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: 8e17
        });
        h.setParams(params);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: uint128(totalSupplyShares),
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp - elapsed),
            fee: uint128(fee)
        });
        h.setMarket(market);

        irm.setRate(ratePerSecond);
        (uint256 grossInterestActual, uint256 protocolFeeActual) = h.accrue(fee);

        assertEq(grossInterestActual, grossInterestExpected);
        assertEq(protocolFeeActual, protocolFeeExpected);
        assertEq(
            uint256(newSupplyExpected) - totalSupplyAssets + protocolFeeExpected,
            grossInterestExpected,
            "net supply growth plus protocol fee must equal gross interest"
        );

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket();
        assertEq(gotMarket.totalBorrowAssets, uint128(newBorrowExpected));
        assertEq(gotMarket.totalSupplyAssets, uint128(newSupplyExpected));
        assertEq(gotMarket.lastUpdate, uint128(block.timestamp));
        assertEq(gotMarket.totalSupplyShares, uint128(totalSupplyShares));
    }

    function test_accrueInterest_zeroElapsed_makesNoStateChanges() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 11,
            collateralPoolId: 22,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: 8e17
        });
        h.setParams(params);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1000,
            totalSupplyShares: 2000,
            totalBorrowAssets: 500,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: uint128(1e17)
        });
        h.setMarket(market);

        irm.setRate(1e14);
        (uint256 interestActual, uint256 protocolFeeActual) = h.accrue(1e17);
        assertEq(interestActual, 0);
        assertEq(protocolFeeActual, 0);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket();
        assertEq(gotMarket.totalSupplyAssets, market.totalSupplyAssets);
        assertEq(gotMarket.totalSupplyShares, market.totalSupplyShares);
        assertEq(gotMarket.totalBorrowAssets, market.totalBorrowAssets);
        assertEq(gotMarket.lastUpdate, market.lastUpdate);
    }

    function _clamp(uint256 x, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        if (minValue == maxValue) {
            return minValue;
        }
        return minValue + (x % (maxValue - minValue + 1));
    }
}

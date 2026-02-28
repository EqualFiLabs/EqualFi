// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {IlmAdaptiveCurveIrm} from "../../src/ilm-isolated/irm/IlmAdaptiveCurveIrm.sol";

contract IlmAdaptiveCurveIrmTest is Test {
    address internal constant OTHER = address(0xBEEF);

    address internal protocolCaller;
    IlmAdaptiveCurveIrm internal irm;

    function setUp() public {
        vm.warp(100 days);
        protocolCaller = address(this);
        irm = new IlmAdaptiveCurveIrm(protocolCaller);
    }

    function test_constructor_rejectsZeroCaller() public {
        vm.expectRevert(IlmAdaptiveCurveIrm.IlmAdaptiveCurveIrmZeroAddress.selector);
        new IlmAdaptiveCurveIrm(address(0));
    }

    function test_borrowRate_rejectsUnauthorizedCaller() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _params(1, 2, 8e17);
        IlmIsolatedTypes.IlmIsolatedMarket memory market = _market(1_000_000, 900_000, block.timestamp - 1 days);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(IlmAdaptiveCurveIrm.IlmAdaptiveCurveIrmUnauthorized.selector, OTHER));
        irm.borrowRate(params, market);
    }

    function test_borrowRate_initialAtTargetUtilization() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _params(11, 22, 8e17);
        IlmIsolatedTypes.IlmIsolatedMarket memory market = _market(1_000_000, 900_000, block.timestamp);
        bytes32 marketId = keccak256(abi.encode(params));

        uint256 rate = irm.borrowRate(params, market);
        assertEq(rate, uint256(irm.INITIAL_RATE_AT_TARGET()));
        assertEq(irm.rateAtTarget(marketId), irm.INITIAL_RATE_AT_TARGET());
    }

    function test_borrowRate_highUtilization_increasesRateAtTarget() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _params(101, 202, 8e17);
        bytes32 marketId = keccak256(abi.encode(params));

        uint256 t0 = block.timestamp;
        irm.borrowRate(params, _market(1_000_000, 900_000, t0));

        vm.warp(t0 + 30 days);
        irm.borrowRate(params, _market(1_000_000, 980_000, block.timestamp - 30 days));

        assertGt(irm.rateAtTarget(marketId), irm.INITIAL_RATE_AT_TARGET());
    }

    function test_borrowRate_lowUtilization_decreasesRateAtTarget() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _params(303, 404, 8e17);
        bytes32 marketId = keccak256(abi.encode(params));

        uint256 t0 = block.timestamp;
        irm.borrowRate(params, _market(1_000_000, 900_000, t0));

        vm.warp(t0 + 30 days);
        irm.borrowRate(params, _market(1_000_000, 100_000, block.timestamp - 30 days));

        assertLt(irm.rateAtTarget(marketId), irm.INITIAL_RATE_AT_TARGET());
    }

    function test_borrowRate_clampsAtMaxAndMinRateAtTarget() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory highParams = _params(501, 502, 8e17);
        bytes32 highMarketId = keccak256(abi.encode(highParams));
        uint256 t0 = block.timestamp;
        irm.borrowRate(highParams, _market(1_000_000, 900_000, t0));

        uint256 ts = t0;
        for (uint256 i = 0; i < 6; ++i) {
            ts += 365 days;
            vm.warp(ts);
            irm.borrowRate(highParams, _market(1_000_000, 1_000_000, ts - 365 days));
        }
        assertEq(irm.rateAtTarget(highMarketId), irm.MAX_RATE_AT_TARGET());

        IlmIsolatedTypes.IlmIsolatedMarketParams memory lowParams = _params(601, 602, 8e17);
        bytes32 lowMarketId = keccak256(abi.encode(lowParams));
        uint256 t1 = block.timestamp;
        irm.borrowRate(lowParams, _market(1_000_000, 900_000, t1));

        uint256 ts2 = t1;
        for (uint256 j = 0; j < 6; ++j) {
            ts2 += 365 days;
            vm.warp(ts2);
            irm.borrowRate(lowParams, _market(1_000_000, 0, ts2 - 365 days));
        }
        assertEq(irm.rateAtTarget(lowMarketId), irm.MIN_RATE_AT_TARGET());
    }

    function test_borrowRate_isMarketIsolated() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsA = _params(701, 702, 8e17);
        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsB = _params(703, 704, 8e17);

        bytes32 marketIdA = keccak256(abi.encode(paramsA));
        bytes32 marketIdB = keccak256(abi.encode(paramsB));
        uint256 t0 = block.timestamp;

        irm.borrowRate(paramsA, _market(1_000_000, 900_000, t0));
        irm.borrowRate(paramsB, _market(1_000_000, 900_000, t0));

        vm.warp(t0 + 20 days);
        irm.borrowRate(paramsA, _market(1_000_000, 980_000, block.timestamp - 20 days));
        irm.borrowRate(paramsB, _market(1_000_000, 100_000, block.timestamp - 20 days));

        assertGt(irm.rateAtTarget(marketIdA), irm.INITIAL_RATE_AT_TARGET());
        assertLt(irm.rateAtTarget(marketIdB), irm.INITIAL_RATE_AT_TARGET());
    }

    function _params(uint256 loanPoolId, uint256 collateralPoolId, uint256 lltv)
        internal
        pure
        returns (IlmIsolatedTypes.IlmIsolatedMarketParams memory params)
    {
        params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: loanPoolId,
            collateralPoolId: collateralPoolId,
            oracle: address(0x1234),
            irm: address(0x7777),
            lltv: lltv
        });
    }

    function _market(uint128 totalSupplyAssets, uint128 totalBorrowAssets, uint256 lastUpdate)
        internal
        pure
        returns (IlmIsolatedTypes.IlmIsolatedMarket memory market)
    {
        market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: 1_000_000,
            lastUpdate: uint128(lastUpdate),
            fee: 0
        });
    }
}

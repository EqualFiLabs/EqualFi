// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {
    RollingError_InvalidAPY,
    RollingError_InvalidGracePeriod,
    RollingError_InvalidInterval,
    RollingError_InvalidPaymentCount,
    RollingError_ExcessivePremium
} from "../../src/libraries/Errors.sol";


/// @notice Feature: p2p-rolling-loans, Property 1: Rolling Parameter Validation Consistency
/// @notice Validates: Requirements 1.1, 1.2, 1.5, 7.1, 7.2, 7.3, 7.4
/// forge-config: default.fuzz.runs = 100
contract DirectRollingValidationPropertyTest is DirectDiamondTestBase {

    function setUp() public {
        setUpDiamond();
    }

    function testProperty_RollingParamValidation() public {
        DirectTypes.DirectRollingConfig memory cfg = _defaultRollingConfig();
        emit log("config ready");
        uint32 baseInterval =
            cfg.minPaymentIntervalSeconds == type(uint32).max ? cfg.minPaymentIntervalSeconds : cfg.minPaymentIntervalSeconds + 1;
        DirectTypes.DirectRollingOfferParams memory params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: 1,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            principal: 1 ether,
            collateralLockAmount: 2 ether,
            paymentIntervalSeconds: baseInterval,
            rollingApyBps: cfg.minRollingApyBps == type(uint16).max ? cfg.minRollingApyBps : cfg.minRollingApyBps + 1,
            gracePeriodSeconds: cfg.minPaymentIntervalSeconds,
            maxPaymentCount: cfg.maxPaymentCount > 0 ? cfg.maxPaymentCount : 1,
            upfrontPremium: 0.4 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: true});

        // Valid baseline
        emit log("baseline valid");
        emit log_named_uint("baseline interval", params.paymentIntervalSeconds);
        harness.validateRollingOfferParams(params, cfg);

        DirectTypes.DirectRollingOfferParams memory shortInterval = _copyParams(params);
        shortInterval.paymentIntervalSeconds = cfg.minPaymentIntervalSeconds > 0 ? cfg.minPaymentIntervalSeconds - 1 : 0;
        emit log("short interval");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_InvalidInterval.selector, shortInterval.paymentIntervalSeconds, cfg.minPaymentIntervalSeconds
        ));
        harness.validateRollingOfferParams(shortInterval, cfg);

        DirectTypes.DirectRollingOfferParams memory tooManyPayments = _copyParams(params);
        tooManyPayments.maxPaymentCount =
            cfg.maxPaymentCount == type(uint16).max ? cfg.maxPaymentCount : cfg.maxPaymentCount + 1;
        emit log_named_uint("too many interval", tooManyPayments.paymentIntervalSeconds);
        emit log_named_uint("cfg min interval", cfg.minPaymentIntervalSeconds);
        emit log_named_uint("too many max count", tooManyPayments.maxPaymentCount);
        emit log("too many payments");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_InvalidPaymentCount.selector, tooManyPayments.maxPaymentCount, cfg.maxPaymentCount
        ));
        harness.validateRollingOfferParams(tooManyPayments, cfg);

        DirectTypes.DirectRollingOfferParams memory badGrace = _copyParams(params);
        badGrace.gracePeriodSeconds = badGrace.paymentIntervalSeconds;
        emit log("bad grace");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_InvalidGracePeriod.selector, badGrace.gracePeriodSeconds, badGrace.paymentIntervalSeconds
        ));
        harness.validateRollingOfferParams(badGrace, cfg);

        DirectTypes.DirectRollingOfferParams memory lowApy = _copyParams(params);
        lowApy.rollingApyBps = cfg.minRollingApyBps > 0 ? cfg.minRollingApyBps - 1 : 0;
        emit log("low apy");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_InvalidAPY.selector, lowApy.rollingApyBps, cfg.minRollingApyBps, cfg.maxRollingApyBps
        ));
        harness.validateRollingOfferParams(lowApy, cfg);

        DirectTypes.DirectRollingOfferParams memory highApy = _copyParams(params);
        highApy.rollingApyBps =
            cfg.maxRollingApyBps == type(uint16).max ? cfg.maxRollingApyBps : cfg.maxRollingApyBps + 1;
        emit log("high apy");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_InvalidAPY.selector, highApy.rollingApyBps, cfg.minRollingApyBps, cfg.maxRollingApyBps
        ));
        harness.validateRollingOfferParams(highApy, cfg);

        DirectTypes.DirectRollingOfferParams memory excessivePremium = _copyParams(params);
        excessivePremium.upfrontPremium = (params.principal * (cfg.maxUpfrontPremiumBps + 1)) / 10_000;
        emit log("excessive premium");
        vm.expectRevert(abi.encodeWithSelector(
            RollingError_ExcessivePremium.selector, excessivePremium.upfrontPremium, (params.principal * (cfg.maxUpfrontPremiumBps)) / 10_000
        ));
        harness.validateRollingOfferParams(excessivePremium, cfg);
    }

    function _defaultRollingConfig() internal pure returns (DirectTypes.DirectRollingConfig memory cfg) {
        cfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
    }

    function _copyParams(DirectTypes.DirectRollingOfferParams memory source)
        internal
        pure
        returns (DirectTypes.DirectRollingOfferParams memory target)
    {
        target = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: source.lenderPositionId,
            lenderPoolId: source.lenderPoolId,
            collateralPoolId: source.collateralPoolId,
            collateralAsset: source.collateralAsset,
            borrowAsset: source.borrowAsset,
            principal: source.principal,
            collateralLockAmount: source.collateralLockAmount,
            paymentIntervalSeconds: source.paymentIntervalSeconds,
            rollingApyBps: source.rollingApyBps,
            gracePeriodSeconds: source.gracePeriodSeconds,
            maxPaymentCount: source.maxPaymentCount,
            upfrontPremium: source.upfrontPremium,
            allowAmortization: source.allowAmortization,
            allowEarlyRepay: source.allowEarlyRepay,
            allowEarlyExercise: source.allowEarlyExercise
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// forge-config: default.optimizer = false

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Feature: p2p-rolling-loans, Property 2: Rolling Agreement Initialization Correctness
/// @notice Validates: Requirements 2.1, 2.2, 2.3
/// forge-config: default.fuzz.runs = 100
contract DirectRollingAgreementPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    struct RollingContext {
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        bytes32 lenderKey;
        bytes32 borrowerKey;
    }

    struct BalanceState {
        uint256 lenderBalanceBefore;
        uint256 borrowerBalanceBefore;
        uint256 agreementId;
    }

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 3_000_000 ether);

        DirectTypes.DirectRollingConfig memory cfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(cfg);
    }

    function testProperty_RollingAgreementInitialization_LenderOffer() public {
        vm.warp(1_000_000);
        RollingContext memory ctx = _setupContext(1, 2, 1, 2, 1_000 ether, 200 ether);
        DirectTypes.DirectRollingOfferParams memory offerParams = _rollingOfferParams(ctx.lenderPositionId, 1, 2);
        BalanceState memory st = _acceptLenderOffer(ctx, offerParams);
        _assertLenderOfferState(ctx, offerParams, st);
    }

    function testProperty_RollingAgreementInitialization_BorrowerOffer() public {
        vm.warp(2_000_000);
        RollingContext memory ctx = _setupContext(3, 4, 3, 4, 800 ether, 300 ether);
        DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams =
            _rollingBorrowerOfferParams(ctx.borrowerPositionId, 3, 4);
        BalanceState memory st = _acceptBorrowerOffer(ctx, borrowerParams);
        _assertBorrowerOfferState(ctx, borrowerParams, st);
    }

    function _setupContext(
        uint256 lenderTokenId,
        uint256 borrowerTokenId,
        uint256 lenderPoolId,
        uint256 borrowerPoolId,
        uint256 lenderSeed,
        uint256 borrowerSeed
    ) internal returns (RollingContext memory ctx) {
        ctx.lenderPositionId = nft.mint(lenderOwner, lenderTokenId);
        ctx.borrowerPositionId = nft.mint(borrowerOwner, borrowerTokenId);
        finalizePositionNFT();
        ctx.lenderKey = nft.getPositionKey(ctx.lenderPositionId);
        ctx.borrowerKey = nft.getPositionKey(ctx.borrowerPositionId);
        harness.seedPoolWithMembership(lenderPoolId, address(asset), ctx.lenderKey, lenderSeed, true);
        harness.seedPoolWithMembership(borrowerPoolId, address(asset), ctx.borrowerKey, borrowerSeed, true);
    }

    function _rollingOfferParams(uint256 lenderPositionId, uint256 lenderPoolId, uint256 collateralPoolId)
        internal
        view
        returns (DirectTypes.DirectRollingOfferParams memory offerParams)
    {
        offerParams.lenderPositionId = lenderPositionId;
        offerParams.lenderPoolId = lenderPoolId;
        offerParams.collateralPoolId = collateralPoolId;
        offerParams.collateralAsset = address(asset);
        offerParams.borrowAsset = address(asset);
        offerParams.principal = 100 ether;
        offerParams.collateralLockAmount = 50 ether;
        offerParams.paymentIntervalSeconds = 604_800;
        offerParams.rollingApyBps = 800;
        offerParams.gracePeriodSeconds = 604_000;
        offerParams.maxPaymentCount = 520;
        offerParams.upfrontPremium = 5 ether;
        offerParams.allowAmortization = true;
        offerParams.allowEarlyRepay = true;
        offerParams.allowEarlyExercise = false;
    }

    function _rollingBorrowerOfferParams(uint256 borrowerPositionId, uint256 lenderPoolId, uint256 collateralPoolId)
        internal
        view
        returns (DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams)
    {
        borrowerParams.borrowerPositionId = borrowerPositionId;
        borrowerParams.lenderPoolId = lenderPoolId;
        borrowerParams.collateralPoolId = collateralPoolId;
        borrowerParams.collateralAsset = address(asset);
        borrowerParams.borrowAsset = address(asset);
        borrowerParams.principal = 120 ether;
        borrowerParams.collateralLockAmount = 60 ether;
        borrowerParams.paymentIntervalSeconds = 604_800;
        borrowerParams.rollingApyBps = 900;
        borrowerParams.gracePeriodSeconds = 604_000;
        borrowerParams.maxPaymentCount = 400;
        borrowerParams.upfrontPremium = 6 ether;
        borrowerParams.allowAmortization = false;
        borrowerParams.allowEarlyRepay = true;
        borrowerParams.allowEarlyExercise = true;
    }

    function _acceptLenderOffer(RollingContext memory ctx, DirectTypes.DirectRollingOfferParams memory offerParams)
        internal
        returns (BalanceState memory st)
    {
        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);
        st.lenderBalanceBefore = asset.balanceOf(lenderOwner);
        st.borrowerBalanceBefore = asset.balanceOf(borrowerOwner);
        vm.prank(borrowerOwner);
        st.agreementId = rollingAgreements.acceptRollingOffer(offerId, ctx.borrowerPositionId);
    }

    function _assertLenderOfferState(
        RollingContext memory ctx,
        DirectTypes.DirectRollingOfferParams memory offerParams,
        BalanceState memory st
    ) internal {
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(st.agreementId);
        assertTrue(agreement.isRolling, "rolling flag set");
        assertEq(agreement.outstandingPrincipal, offerParams.principal, "outstanding principal stored");
        assertEq(agreement.arrears, 0, "arrears zero");
        assertEq(agreement.paymentCount, 0, "paymentCount zero");
        assertEq(agreement.lastAccrualTimestamp, block.timestamp, "last accrual");
        assertEq(agreement.nextDue, block.timestamp + offerParams.paymentIntervalSeconds, "next due set");
        assertEq(views.offerEscrow(ctx.lenderKey, offerParams.lenderPoolId), 0, "escrow released");
        assertEq(
            views.directLocked(ctx.borrowerKey, offerParams.collateralPoolId),
            offerParams.collateralLockAmount,
            "collateral locked"
        );
        assertEq(
            rollingAgreements.getRollingAgreement(st.agreementId).upfrontPremium,
            offerParams.upfrontPremium,
            "premium stored"
        );
        assertEq(asset.balanceOf(lenderOwner), st.lenderBalanceBefore + offerParams.upfrontPremium, "premium to lender");
        assertEq(
            asset.balanceOf(borrowerOwner),
            st.borrowerBalanceBefore + offerParams.principal - offerParams.upfrontPremium,
            "net principal to borrower"
        );
    }

    function _acceptBorrowerOffer(
        RollingContext memory ctx,
        DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams
    ) internal returns (BalanceState memory st) {
        vm.prank(borrowerOwner);
        uint256 borrowerOfferId = rollingOffers.postBorrowerRollingOffer(borrowerParams);
        st.lenderBalanceBefore = asset.balanceOf(lenderOwner);
        st.borrowerBalanceBefore = asset.balanceOf(borrowerOwner);
        vm.prank(lenderOwner);
        st.agreementId = rollingAgreements.acceptRollingOffer(borrowerOfferId, ctx.lenderPositionId);
    }

    function _assertBorrowerOfferState(
        RollingContext memory ctx,
        DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams,
        BalanceState memory st
    ) internal {
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(st.agreementId);
        assertEq(agreement.outstandingPrincipal, borrowerParams.principal, "outstanding principal stored");
        assertEq(agreement.arrears, 0, "arrears zero");
        assertEq(agreement.paymentCount, 0, "paymentCount zero");
        assertEq(agreement.nextDue, block.timestamp + borrowerParams.paymentIntervalSeconds, "next due set");
        assertEq(agreement.borrowerPositionId, ctx.borrowerPositionId, "borrower position stored");
        assertEq(asset.balanceOf(lenderOwner), st.lenderBalanceBefore + borrowerParams.upfrontPremium, "premium to lender");
        assertEq(
            asset.balanceOf(borrowerOwner),
            st.borrowerBalanceBefore + borrowerParams.principal - borrowerParams.upfrontPremium,
            "net principal to borrower"
        );
    }
}

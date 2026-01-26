// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";

contract DirectLifecycleGasTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Asset", "AST", 18, 5_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
    }

    function _seedAgreement() internal returns (uint256 agreementId, uint256 lenderPos, uint256 borrowerPos) {
        lenderPos = nft.mint(lenderOwner, 1);
        borrowerPos = nft.mint(borrowerOwner, 1);
        finalizePositionNFT();

        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.initPool(1, address(asset), 1, 1, 8000);
        harness.seedPosition(1, lenderKey, 500 ether);
        harness.seedPosition(1, borrowerKey, 500 ether);

        agreementId = 1;
        DirectTypes.DirectAgreement memory agreement = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: lenderOwner,
            borrower: borrowerOwner,
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            borrowerPositionId: borrowerPos,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            userInterest: 0,
            dueTimestamp: uint64(block.timestamp + 7 days),
            collateralLockAmount: 200 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: true,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: false
        });
        harness.setAgreement(agreement);
        harness.setDirectState(borrowerKey, lenderKey, 1, 1, agreement.collateralLockAmount, agreement.principal, agreementId);
    }

    function test_gas_DirectExercise() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _seedAgreement();

        vm.prank(borrowerOwner);
        vm.resumeGasMetering();
        lifecycle.exerciseDirect(agreementId);
    }

    function test_gas_DirectCall() public {
        vm.pauseGasMetering();
        (uint256 agreementId, uint256 lenderPos,) = _seedAgreement();
        vm.assume(lenderPos != 0);

        vm.prank(lenderOwner);
        vm.resumeGasMetering();
        lifecycle.callDirect(agreementId);
    }
}

contract DirectOfferGasTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("TokenA", "TKA", 18, 1_000_000 ether);
        tokenB = new MockERC20("TokenB", "TKB", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
    }

    function _seedPositions()
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lender, 1);
        borrowerPos = nft.mint(borrower, 2);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(1, address(tokenA), lenderKey, 200 ether, 8000, true);
        harness.seedPoolWithLtv(2, address(tokenB), borrowerKey, 100 ether, 8000, true);
    }

    function _baseOffer(uint256 lenderPos) internal view returns (DirectTypes.DirectOfferParams memory params) {
        params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });
    }

    function test_gas_CancelOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions();
        DirectTypes.DirectOfferParams memory params = _baseOffer(lenderPos);

        vm.prank(lender);
        uint256 offerId = offers.postOffer(params);

        vm.prank(lender);
        vm.resumeGasMetering();
        offers.cancelOffer(offerId);
    }

    function test_gas_CancelBorrowerOffer() public {
        vm.pauseGasMetering();
        (, uint256 borrowerPos,,) = _seedPositions();
        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 40 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 15 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrower);
        uint256 offerId = offers.postBorrowerOffer(params);

        vm.prank(borrower);
        vm.resumeGasMetering();
        offers.cancelBorrowerOffer(offerId);
    }

    function test_gas_CancelRatioTrancheOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions();
        DirectTypes.DirectRatioTrancheParams memory params = DirectTypes.DirectRatioTrancheParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principalCap: 50 ether,
            priceNumerator: 2,
            priceDenominator: 1,
            minPrincipalPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        vm.prank(lender);
        vm.resumeGasMetering();
        offers.cancelRatioTrancheOffer(offerId);
    }

    function test_gas_CancelBorrowerRatioTrancheOffer() public {
        vm.pauseGasMetering();
        (, uint256 borrowerPos,,) = _seedPositions();
        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            collateralCap: 50 ether,
            priceNumerator: 1,
            priceDenominator: 2,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrower);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.prank(borrower);
        vm.resumeGasMetering();
        offers.cancelBorrowerRatioTrancheOffer(offerId);
    }

    function test_gas_CancelOffersForPositionById() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions();
        DirectTypes.DirectOfferParams memory params = _baseOffer(lenderPos);
        vm.prank(lender);
        offers.postOffer(params);

        vm.prank(lender);
        vm.resumeGasMetering();
        offers.cancelOffersForPosition(lenderPos);
    }

    function test_gas_CancelOffersForPositionByKey() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,, bytes32 lenderKey,) = _seedPositions();
        DirectTypes.DirectOfferParams memory params = _baseOffer(lenderPos);
        vm.prank(lender);
        offers.postOffer(params);

        vm.resumeGasMetering();
        offers.cancelOffersForPosition(lenderKey);
    }

    function test_gas_HasOpenOffers() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,, bytes32 lenderKey,) = _seedPositions();
        DirectTypes.DirectOfferParams memory params = _baseOffer(lenderPos);
        vm.prank(lender);
        offers.postOffer(params);

        vm.resumeGasMetering();
        offers.hasOpenOffers(lenderKey);
    }
}

contract DirectRollingGasTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    MockERC20 internal collateral;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Asset", "AST", 18, 5_000_000 ether);
        collateral = new MockERC20("Collateral", "COL", 18, 5_000_000 ether);

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 1 days,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 0,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
    }

    function _seedPositions(uint256 lenderPool, uint256 borrowerPool)
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lenderOwner, lenderPool);
        borrowerPos = nft.mint(borrowerOwner, borrowerPool);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(lenderPool, address(asset), lenderKey, 1_000 ether, 8000, true);
        harness.seedPoolWithLtv(borrowerPool, address(asset), borrowerKey, 300 ether, 8000, true);
    }

    function _seedPositionsWithAssets(
        uint256 lenderPool,
        uint256 borrowerPool,
        address lenderAsset,
        address collateralAsset
    )
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lenderOwner, lenderPool);
        borrowerPos = nft.mint(borrowerOwner, borrowerPool);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(lenderPool, lenderAsset, lenderKey, 1_000 ether, 8000, true);
        harness.seedPoolWithLtv(borrowerPool, collateralAsset, borrowerKey, 300 ether, 8000, true);
    }

    function _rollingOfferParams(uint256 lenderPos, uint256 lenderPool, uint256 collateralPool, bool allowEarlyExercise, bool allowEarlyRepay)
        internal
        view
        returns (DirectTypes.DirectRollingOfferParams memory params)
    {
        params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: lenderPool,
            collateralPoolId: collateralPool,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 520,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: allowEarlyRepay,
            allowEarlyExercise: allowEarlyExercise
        });
    }

    function _setupAgreement(bool allowEarlyExercise, bool allowEarlyRepay)
        internal
        returns (uint256 agreementId, uint256 lenderPos, uint256 borrowerPos)
    {
        (lenderPos, borrowerPos,,) = _seedPositions(1, 1);
        DirectTypes.DirectRollingOfferParams memory params =
            _rollingOfferParams(lenderPos, 1, 1, allowEarlyExercise, allowEarlyRepay);

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);
        vm.prank(borrowerOwner);
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPos);
    }

    function test_gas_PostRollingOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingOfferParams memory params =
            _rollingOfferParams(lenderPos, 1, 2, false, false);

        vm.prank(lenderOwner);
        vm.resumeGasMetering();
        rollingOffers.postRollingOffer(params);
    }

    function test_gas_PostBorrowerRollingOffer() public {
        vm.pauseGasMetering();
        (, uint256 borrowerPos,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingBorrowerOfferParams memory params = DirectTypes.DirectRollingBorrowerOfferParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 120 ether,
            collateralLockAmount: 60 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 900,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 400,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: true
        });

        vm.prank(borrowerOwner);
        vm.resumeGasMetering();
        rollingOffers.postBorrowerRollingOffer(params);
    }

    function test_gas_CancelRollingOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingOfferParams memory params =
            _rollingOfferParams(lenderPos, 1, 2, false, false);

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);

        vm.prank(lenderOwner);
        vm.resumeGasMetering();
        rollingOffers.cancelRollingOffer(offerId);
    }

    function test_gas_AcceptRollingOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos, uint256 borrowerPos,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingOfferParams memory params =
            _rollingOfferParams(lenderPos, 1, 2, false, false);

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);

        vm.prank(borrowerOwner);
        vm.resumeGasMetering();
        rollingAgreements.acceptRollingOffer(offerId, borrowerPos);
    }

    function test_gas_MakeRollingPayment() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);
        uint256 payAmount = 10 ether;
        asset.mint(borrowerOwner, payAmount);
        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), payAmount);
        vm.resumeGasMetering();
        rollingPayments.makeRollingPayment(agreementId, payAmount);
        vm.stopPrank();
    }

    function test_gas_ExerciseRolling() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, false);

        vm.prank(borrowerOwner);
        vm.resumeGasMetering();
        rollingLifecycle.exerciseRolling(agreementId);
    }

    function test_gas_RepayRollingInFull() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);
        asset.mint(borrowerOwner, 200 ether);

        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.resumeGasMetering();
        rollingLifecycle.repayRollingInFull(agreementId);
        vm.stopPrank();
    }

    function test_gas_RecoverRolling() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);
        vm.warp(10 days);
        harness.forceNextDue(agreementId, uint64(block.timestamp - 8 days));

        vm.prank(lenderOwner);
        vm.resumeGasMetering();
        rollingLifecycle.recoverRolling(agreementId);
    }

    function test_gas_GetRollingAgreement() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);

        vm.resumeGasMetering();
        rollingAgreements.getRollingAgreement(agreementId);
    }

    function test_gas_GetRollingOffer() public {
        vm.pauseGasMetering();
        (uint256 lenderPos,,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingOfferParams memory params =
            _rollingOfferParams(lenderPos, 1, 2, false, false);

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);

        vm.resumeGasMetering();
        rollingOffers.getRollingOffer(offerId);
    }

    function test_gas_GetRollingBorrowerOffer() public {
        vm.pauseGasMetering();
        (, uint256 borrowerPos,,) = _seedPositions(1, 2);
        DirectTypes.DirectRollingBorrowerOfferParams memory params = DirectTypes.DirectRollingBorrowerOfferParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 120 ether,
            collateralLockAmount: 60 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 900,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 400,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: true
        });

        vm.prank(borrowerOwner);
        uint256 offerId = rollingOffers.postBorrowerRollingOffer(params);

        vm.resumeGasMetering();
        rollingOffers.getRollingBorrowerOffer(offerId);
    }

    function test_gas_CalculateRollingPayment() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);

        vm.resumeGasMetering();
        rollingViews.calculateRollingPayment(agreementId);
    }

    function test_gas_GetRollingStatus() public {
        vm.pauseGasMetering();
        (uint256 agreementId,,) = _setupAgreement(true, true);

        vm.resumeGasMetering();
        rollingViews.getRollingStatus(agreementId);
    }

    function test_gas_AggregateRollingExposure() public {
        vm.pauseGasMetering();
        (uint256 agreementId, uint256 lenderPos, uint256 borrowerPos) = _setupAgreement(true, true);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        vm.assume(agreementId != 0 && lenderPos != 0);

        vm.resumeGasMetering();
        rollingViews.aggregateRollingExposure(borrowerKey);
    }
}

contract DiamondLoupeGasTest is DirectDiamondTestBase {
    address internal loupeFacet;

    function setUp() public {
        setUpDiamond();
        address[] memory facets = IDiamondLoupe(address(diamond)).facetAddresses();
        loupeFacet = facets[0];
    }

    function test_gas_LoupeFacetFunctionSelectors() public {
        vm.resumeGasMetering();
        IDiamondLoupe(address(diamond)).facetFunctionSelectors(loupeFacet);
    }

    function test_gas_LoupeFacetAddresses() public {
        vm.resumeGasMetering();
        IDiamondLoupe(address(diamond)).facetAddresses();
    }

    function test_gas_LoupeFacetAddress() public {
        vm.resumeGasMetering();
        IDiamondLoupe(address(diamond)).facetAddress(DiamondCutFacet.diamondCut.selector);
    }

    function test_gas_LoupeSupportsInterface() public {
        vm.resumeGasMetering();
        IDiamondLoupe(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId);
    }
}

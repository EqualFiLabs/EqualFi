// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {InsufficientPrincipal} from "../../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

/// @notice Feature: direct-limit-orders, Property 11: Auto-Exercise Removal
/// @notice Validates: Requirements 10.1, 10.2, 10.3
/// forge-config: default.fuzz.runs = 100
contract DirectRatioTrancheNoAutoExercisePropertyTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 1_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 1_000_000 ether);
    }

    function testProperty_RatioTrancheAutoExerciseRemoved(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 principalCap,
        uint256 fillAmount
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0));
        vm.assume(lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);

        principalCap = bound(principalCap, 1, 1_000_000 ether);
        fillAmount = bound(fillAmount, 1, principalCap);
        lenderPrincipal = bound(lenderPrincipal, principalCap, 1_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, fillAmount, 1_000_000 ether);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenB), borrowerKey, borrowerPrincipal, 10_000, true);

        DirectTypes.DirectRatioTrancheParams memory params = DirectTypes.DirectRatioTrancheParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principalCap: principalCap,
            priceNumerator: 1,
            priceDenominator: 1,
            minPrincipalPerFill: 1,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptRatioTrancheOffer(offerId, borrowerPos, fillAmount, 0);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement should be active");
        assertEq(views.directLocked(borrowerKey, COLLATERAL_POOL), fillAmount, "collateral remains locked");
    }

    function testProperty_BorrowerRatioTrancheAutoExerciseRemoved(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 collateralCap,
        uint256 fillCollateral
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0));
        vm.assume(lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);

        collateralCap = bound(collateralCap, 1, 1_000_000 ether);
        fillCollateral = bound(fillCollateral, 1, collateralCap);
        lenderPrincipal = bound(lenderPrincipal, fillCollateral, 1_000_000 ether);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenB), borrowerKey, collateralCap, 10_000, true);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            collateralCap: collateralCap,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, fillCollateral, 0);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement should be active");
        assertEq(views.directLocked(borrowerKey, COLLATERAL_POOL), collateralCap, "collateral remains locked");
    }

    function test_BorrowerRatioAcceptance_RevertsWhenEscrowCommitsCapacity() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, 100 ether, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenB), borrowerKey, 100 ether, 10_000, true);

        DirectTypes.DirectOfferParams memory escrowOffer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 80 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        offers.postOffer(escrowOffer);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            collateralCap: 50 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 30 ether, 20 ether));
        vm.prank(lenderOwner);
        agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, 30 ether, 0);
    }

    function test_BorrowerRatioAcceptance_SucceedsAtUnencumberedCapacity() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, 100 ether, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenB), borrowerKey, 100 ether, 10_000, true);

        DirectTypes.DirectOfferParams memory escrowOffer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 80 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        offers.postOffer(escrowOffer);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            collateralCap: 50 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, 20 ether, 0);
        assertGt(agreementId, 0, "agreement created at available capacity");

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.principal, 20 ether, "principal matches accepted fill");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 80 ether, "existing offer escrow preserved");
        assertEq(
            views.getBorrowerRatioTrancheOffer(offerId).collateralRemaining,
            30 ether,
            "borrower ratio collateral remaining decremented"
        );
    }

    function test_BorrowerRatioSameAsset_RevertsWhenFillBreachesBorrowerLtv() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, 200 ether, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenA), borrowerKey, 100 ether, 5_000, true);
        harness.setDirectBorrowed(borrowerKey, LENDER_POOL, 40 ether);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenA),
            borrowAsset: address(tokenA),
            collateralCap: 30 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.expectRevert(bytes("SolvencyViolation: Borrower LTV"));
        vm.prank(lenderOwner);
        agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, 20 ether, 0);
    }

    function test_BorrowerRatioSameAsset_SucceedsWhenWithinBorrowerLtv() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, 200 ether, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenA), borrowerKey, 100 ether, 5_000, true);
        harness.setDirectBorrowed(borrowerKey, LENDER_POOL, 20 ether);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenA),
            borrowAsset: address(tokenA),
            collateralCap: 30 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, 20 ether, 0);
        assertGt(agreementId, 0, "agreement created within borrower LTV");
        assertEq(views.getBorrowerRatioTrancheOffer(offerId).collateralRemaining, 10 ether, "remaining decremented");
    }

    function test_BorrowerRatioDifferentAsset_AllowsFillWithoutSameAssetSolvencyGate() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithLtv(LENDER_POOL, address(tokenA), lenderKey, 200 ether, 10_000, true);
        harness.seedPoolWithLtv(COLLATERAL_POOL, address(tokenB), borrowerKey, 100 ether, 1_000, true);
        harness.setDirectBorrowed(borrowerKey, LENDER_POOL, 90 ether);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            collateralCap: 30 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerRatioTrancheOffer(params);

        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, 20 ether, 0);
        assertGt(agreementId, 0, "different-asset fill remains allowed");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

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
        uint256 agreementId = agreements.acceptRatioTrancheOffer(offerId, borrowerPos, fillAmount);

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
        uint256 agreementId = agreements.acceptBorrowerRatioTrancheOffer(offerId, lenderPos, fillCollateral);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement should be active");
        assertEq(views.directLocked(borrowerKey, COLLATERAL_POOL), collateralCap, "collateral remains locked");
    }
}

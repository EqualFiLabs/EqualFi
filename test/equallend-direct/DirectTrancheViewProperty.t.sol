// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: tranche-backed-offers, Property 10: View function accuracy
/// @notice Validates: Requirements 5.1, 5.2
/// forge-config: default.fuzz.runs = 100
contract DirectTrancheViewPropertyTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;
    address internal protocolTreasury = address(0xFEE1);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 5_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 5_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_ViewFunctionAccuracy(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 trancheAmount,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0));
        vm.assume(borrowerOwner != address(0));
        vm.assume(lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0);
        vm.assume(borrowerOwner.code.length == 0);

        principal = bound(principal, 1 ether, 1_000_000 ether);
        trancheAmount = bound(trancheAmount, principal, 2_000_000 ether);
        lenderPrincipal = bound(lenderPrincipal, trancheAmount, 5_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, principal * 2, 5_000_000 ether);

        harness.setEnforceFixedSizeFills(false);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, borrowerPrincipal, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: principal,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, tranche);

        DirectTypes.DirectTrancheView memory status = views.getOfferTranche(offerId);
        uint256 expectedFills = trancheAmount / principal;
        assertTrue(status.isTranche, "tranche flag");
        assertEq(status.trancheAmount, trancheAmount, "tranche amount");
        assertEq(status.trancheRemaining, trancheAmount, "tranche remaining");
        assertEq(status.principalPerFill, principal, "principal per fill");
        assertEq(status.fillsRemaining, expectedFills, "fills remaining");
        assertFalse(status.isDepleted, "not depleted on post");
        assertTrue(views.isTrancheOffer(offerId), "is tranche offer view");
        assertFalse(views.isTrancheDepleted(offerId), "not depleted view");
        assertEq(views.fillsRemaining(offerId), expectedFills, "fillsRemaining view");

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        DirectTypes.DirectTrancheView memory afterStatus = views.getTrancheStatus(offerId);
        uint256 expectedRemaining = trancheAmount - principal;
        uint256 expectedAfterFills = expectedRemaining / principal;
        bool expectedDepleted = expectedRemaining == 0;
        assertEq(afterStatus.trancheRemaining, expectedRemaining, "remaining after accept");
        assertEq(afterStatus.fillsRemaining, expectedAfterFills, "fills after accept");
        assertEq(afterStatus.isDepleted, expectedDepleted, "depletion flag");
        assertEq(views.fillsRemaining(offerId), expectedAfterFills, "fills view after accept");
        assertEq(views.isTrancheDepleted(offerId), expectedDepleted, "depleted view after accept");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectError_InvalidTrancheAmount} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: tranche-backed-offers, Property 1: Tranche offer initialization correctness
/// @notice Validates: Requirements 1.1, 1.2, 1.3
/// forge-config: default.fuzz.runs = 100
contract DirectTrancheOfferPostingPropertyTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    address internal protocolTreasury = address(0xFEE1);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 1_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 1_000_000 ether);

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

    function testProperty_TrancheOfferInitializationCorrectness(
        address lenderOwner,
        uint256 lenderPrincipal,
        uint256 trancheAmount,
        uint256 principal,
        bool enforceDivisibility
    ) public {
        vm.assume(lenderOwner != address(0));
        vm.assume(lenderOwner.code.length == 0);
        principal = bound(principal, 1, 1_000_000 ether);
        trancheAmount = bound(trancheAmount, principal, 2_000_000 ether);
        lenderPrincipal = bound(lenderPrincipal, trancheAmount, 5_000_000 ether);

        harness.setEnforceFixedSizeFills(enforceDivisibility);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, false);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, lenderPrincipal, false);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        if (enforceDivisibility && trancheAmount % principal != 0) {
            vm.expectRevert(DirectError_InvalidTrancheAmount.selector);
            vm.prank(lenderOwner);
            offers.postOffer(params, tranche);
            return;
        }

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, tranche);

        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertTrue(stored.isTranche, "isTranche set");
        assertEq(stored.trancheAmount, trancheAmount, "tranche amount set");
        assertEq(views.trancheRemaining(offerId), trancheAmount, "tranche remaining initialized");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), trancheAmount, "escrowed full tranche");
    }

    /// @notice Feature: tranche-backed-offers, Property 2: Encumbrance accounting invariant (CRITICAL)
    /// @notice Validates: Requirements 6.4, 4.7
    /// forge-config: default.fuzz.runs = 100
    function testProperty_EncumbranceAccountingInvariant(
        address lenderOwner,
        uint256 trancheAmountOne,
        uint256 trancheAmountTwo,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0) && lenderOwner.code.length == 0);
        principal = bound(principal, 1, 1_000_000 ether);
        trancheAmountOne = bound(trancheAmountOne, principal, 2_000_000 ether);
        trancheAmountTwo = bound(trancheAmountTwo, principal, 2_000_000 ether);

        uint256 totalPrincipal = trancheAmountOne + trancheAmountTwo + principal;
        harness.setEnforceFixedSizeFills(false);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, totalPrincipal, false);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, totalPrincipal, false);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory trancheOne =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmountOne});
        DirectTypes.DirectTrancheOfferParams memory trancheTwo =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmountTwo});

        vm.prank(lenderOwner);
        uint256 offerOne = offers.postOffer(params, trancheOne);
        vm.prank(lenderOwner);
        uint256 offerTwo = offers.postOffer(params, trancheTwo);

        uint256 escrow = views.offerEscrow(lenderKey, LENDER_POOL);
        uint256 remainingSum = views.trancheRemaining(offerOne) + views.trancheRemaining(offerTwo);
        assertEq(escrow, remainingSum, "escrow equals sum of tranche remaining");
    }

    /// @notice Feature: tranche-backed-offers, Property 2 (extended): no orphaned escrow after cancellation
    /// @notice Validates: Requirements 6.3, 6.4, 6.5
    function testProperty_EncumbranceCleanup(
        address lenderOwner,
        uint256 trancheAmountOne,
        uint256 trancheAmountTwo,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0) && lenderOwner.code.length == 0);
        principal = bound(principal, 1, 1_000_000 ether);
        trancheAmountOne = bound(trancheAmountOne, principal, 2_000_000 ether);
        trancheAmountTwo = bound(trancheAmountTwo, principal, 2_000_000 ether);

        uint256 totalPrincipal = trancheAmountOne + trancheAmountTwo + principal;
        harness.setEnforceFixedSizeFills(false);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, totalPrincipal, false);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, totalPrincipal, false);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory trancheOne =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmountOne});
        DirectTypes.DirectTrancheOfferParams memory trancheTwo =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmountTwo});

        vm.prank(lenderOwner);
        uint256 offerOne = offers.postOffer(params, trancheOne);
        vm.prank(lenderOwner);
        uint256 offerTwo = offers.postOffer(params, trancheTwo);

        // Cancel one offer; escrow should drop by its remaining amount
        uint256 escrowBefore = views.offerEscrow(lenderKey, LENDER_POOL);
        uint256 remainingBefore = views.trancheRemaining(offerOne) + views.trancheRemaining(offerTwo);
        assertEq(escrowBefore, remainingBefore, "escrow tracks sum pre-cancel");

        vm.prank(lenderOwner);
        offers.cancelOffer(offerOne);

        uint256 escrowAfter = views.offerEscrow(lenderKey, LENDER_POOL);
        uint256 remainingAfter = views.trancheRemaining(offerOne) + views.trancheRemaining(offerTwo);
        assertEq(views.trancheRemaining(offerOne), 0, "first offer cleared");
        assertEq(escrowAfter, remainingAfter, "escrow tracks remaining after cancel");
    }
}

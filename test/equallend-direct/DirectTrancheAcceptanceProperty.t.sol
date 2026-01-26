// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: tranche-backed-offers, Property 3/4/5/9 tranche acceptance behaviors
/// forge-config: default.fuzz.runs = 100
contract DirectTrancheAcceptancePropertyTest is DirectDiamondTestBase {
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

    function _postTrancheOffer(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 principal,
        uint256 trancheAmount
    ) internal returns (uint256 offerId, uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) {
        return _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount, false);
    }

    function _postTrancheOffer(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 principal,
        uint256 trancheAmount,
        bool sameAsset
    ) internal returns (uint256 offerId, uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) {
        lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        address collateralUnderlying = sameAsset ? address(tokenA) : address(tokenB);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, collateralUnderlying, borrowerKey, borrowerPrincipal, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: collateralUnderlying,
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: borrowerPrincipal > 0 ? borrowerPrincipal / 2 : 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        vm.prank(lenderOwner);
        offerId = offers.postOffer(params, tranche);
    }

    /// @notice Feature: tranche-backed-offers, Property 3: Atomic tranche acceptance
    /// @notice Validates: Requirements 2.1, 2.3, 6.1
    function testProperty_AtomicTrancheAcceptance(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 principal,
        uint256 trancheAmount
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 500_000 ether);
        trancheAmount = bound(trancheAmount, principal * 2, 1_000_000 ether);
        lenderPrincipal = bound(lenderPrincipal, trancheAmount, 2_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, principal * 2, 2_000_000 ether);

        (uint256 offerId, uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount);
        _finalizeMinter();

        uint256 remainingBefore = views.trancheRemaining(offerId);
        uint256 escrowBefore = views.offerEscrow(lenderKey, LENDER_POOL);
        (uint256 lockedBefore,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        uint256 lenderLentBefore = views.directLent(lenderKey, LENDER_POOL);
        uint256 borrowerDebtBefore = views.directBorrowed(borrowerKey, LENDER_POOL);
        uint256 activeBefore = views.getActiveDirectLent(LENDER_POOL);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);
        assertGt(agreementId, 0, "agreement created");

        uint256 remainingAfter = views.trancheRemaining(offerId);
        assertEq(remainingAfter, remainingBefore - principal, "tranche decremented atomically");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), escrowBefore - principal, "escrow decremented");

        (uint256 lockedAfter, uint256 borrowerLentAfter) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        uint256 lenderLentAfter = views.directLent(lenderKey, LENDER_POOL);
        uint256 borrowerDebtAfter = views.directBorrowed(borrowerKey, LENDER_POOL);
        assertEq(lockedAfter, lockedBefore + borrowerPrincipal / 2, "collateral locked");
        assertEq(borrowerLentAfter, 0, "borrower debt tracked in lender pool only");
        assertEq(lenderLentAfter, lenderLentBefore + principal, "lender lent updated");
        assertEq(borrowerDebtAfter, borrowerDebtBefore + principal, "borrower debt updated");
        assertEq(views.getActiveDirectLent(LENDER_POOL), activeBefore + principal, "active lent updated");

        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertFalse(stored.filled, "offer remains open while tranche remains");
    }

    /// @notice Feature: tranche-backed-offers, Property 4: Tranche depletion handling
    /// @notice Validates: Requirements 2.5
    function testProperty_TrancheDepletionHandling(address lenderOwner, address borrowerOwner, uint256 principal) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 500_000 ether);
        uint256 trancheAmount = principal;
        uint256 lenderPrincipal = principal * 2;
        uint256 borrowerPrincipal = principal * 2;

        (uint256 offerId, uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey,) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount);
        _finalizeMinter();

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);
        assertGt(agreementId, 0, "agreement created");

        assertEq(views.trancheRemaining(offerId), 0, "tranche depleted");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 0, "escrow cleared");
        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertTrue(stored.filled, "offer closed on depletion");
    }

    /// @notice Feature: tranche-backed-offers, Property 5: Escrow-to-lent transfer consistency
    /// @notice Validates: Requirements 2.4, 4.7
    function testProperty_EscrowToLentConsistency(
        address lenderOwner,
        address borrowerOwner,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 principal,
        uint256 trancheAmount
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 500_000 ether);
        trancheAmount = bound(trancheAmount, principal, 1_000_000 ether);
        lenderPrincipal = bound(lenderPrincipal, trancheAmount, 2_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, principal * 2, 2_000_000 ether);

        (uint256 offerId, uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey,) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount);
        _finalizeMinter();

        uint256 escrowBefore = views.offerEscrow(lenderKey, LENDER_POOL);
        uint256 lenderLentBefore = views.directLent(lenderKey, LENDER_POOL);

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        uint256 escrowAfter = views.offerEscrow(lenderKey, LENDER_POOL);
        uint256 lenderLentAfter = views.directLent(lenderKey, LENDER_POOL);
        assertEq(escrowBefore - escrowAfter, lenderLentAfter - lenderLentBefore, "escrow decrease equals lent increase");
    }

    /// @notice Feature: tranche-backed-offers, Property 9: Auto-cancellation determinism
    /// @notice Validates: Requirements 2.2, 6.2, 7.2
    function testProperty_AutoCancellationDeterminism(
        address lenderOwner,
        address borrowerOwner,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 100 ether);
        uint256 trancheAmount = principal * 2;
        uint256 lenderPrincipal = principal * 10;
        uint256 borrowerPrincipal = principal * 10;

        (uint256 offerId,, uint256 borrowerPos, bytes32 lenderKey,) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount);
        _finalizeMinter();

        // Force insufficient tranche remaining before acceptance attempt
        harness.setTrancheState(lenderKey, LENDER_POOL, offerId, principal - 1, principal);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);
        assertEq(agreementId, 0, "no agreement created");

        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertTrue(stored.cancelled, "offer cancelled on insufficiency");
        assertTrue(stored.filled, "offer closed on insufficiency");
        assertEq(views.trancheRemaining(offerId), 0, "tranche zeroed");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 0, "escrow cleared");
    }

    /// @notice Feature: tranche-backed-offers, Property 6: Active credit integration consistency
    /// @notice Validates: Requirements 4.2, 4.3, 4.4
    function testProperty_ActiveCreditIntegrationConsistency(
        address lenderOwner,
        address borrowerOwner,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 100_000 ether);
        uint256 trancheAmount = principal * 2;
        uint256 lenderPrincipal = trancheAmount * 2;
        uint256 borrowerPrincipal = principal * 10;

        (uint256 offerId,, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount, true);
        _finalizeMinter();

        uint256 lenderEncBefore = views.activeCreditEncumbrance(lenderKey, LENDER_POOL);
        uint256 borrowerDebtBefore = views.activeCreditDebt(borrowerKey, COLLATERAL_POOL);
        uint256 poolDebtBefore = views.poolActiveCreditTotal(COLLATERAL_POOL);

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        uint256 lenderEncAfter = views.activeCreditEncumbrance(lenderKey, LENDER_POOL);
        uint256 borrowerDebtAfter = views.activeCreditDebt(borrowerKey, COLLATERAL_POOL);
        uint256 poolDebtAfter = views.poolActiveCreditTotal(COLLATERAL_POOL);

        assertEq(lenderEncAfter, lenderEncBefore, "lender active credit unchanged");
        assertEq(borrowerDebtAfter, borrowerDebtBefore + principal, "borrower debt active credit increased (same asset)");
        uint256 collateralLock = borrowerPrincipal / 2;
        assertEq(
            poolDebtAfter,
            poolDebtBefore + principal + collateralLock,
            "pool debt active credit total increased"
        );
    }

    /// @notice Feature: tranche-backed-offers, Property 8: Multi-fill independence
    /// @notice Validates: Requirements 4.1, 4.5
    function testProperty_MultiFillIndependence(
        address lenderOwner,
        address borrowerOwner,
        uint256 principal
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerOwner != address(0) && lenderOwner != borrowerOwner);
        vm.assume(lenderOwner.code.length == 0 && borrowerOwner.code.length == 0);
        principal = bound(principal, 1 ether, 50_000 ether);
        uint256 trancheAmount = principal * 3;
        uint256 lenderPrincipal = trancheAmount * 2;
        uint256 borrowerPrincipal = principal * 10;

        (uint256 offerId,, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) =
            _postTrancheOffer(lenderOwner, borrowerOwner, lenderPrincipal, borrowerPrincipal, principal, trancheAmount, true);
        _finalizeMinter();

        uint256 lenderEncBefore = views.activeCreditEncumbrance(lenderKey, LENDER_POOL);
        uint256 borrowerDebtBefore = views.activeCreditDebt(borrowerKey, COLLATERAL_POOL);

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        assertEq(views.trancheRemaining(offerId), trancheAmount - (principal * 2), "remaining after two fills");
        assertEq(views.activeCreditEncumbrance(lenderKey, LENDER_POOL), lenderEncBefore, "lender active credit unchanged");
        assertEq(views.activeCreditDebt(borrowerKey, COLLATERAL_POOL), borrowerDebtBefore + principal * 2, "borrower debt per fill");
    }

    /// @notice Property: concurrent acceptance attempts cannot overdraw tranche; first fill wins
    /// @notice Validates: Requirements 6.1
    function testProperty_ConcurrentAcceptanceAtomicity(
        address lenderOwner,
        address borrowerA,
        address borrowerB,
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal
    ) public {
        vm.assume(lenderOwner != address(0) && borrowerA != address(0) && borrowerB != address(0));
        vm.assume(lenderOwner != borrowerA && lenderOwner != borrowerB);
        vm.assume(borrowerA != borrowerB);
        vm.assume(lenderOwner.code.length == 0 && borrowerA.code.length == 0 && borrowerB.code.length == 0);

        uint256 principal = 100 ether;
        uint256 trancheAmount = principal; // single-fill tranche
        lenderPrincipal = bound(lenderPrincipal, trancheAmount, 1_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, principal * 2, 1_000_000 ether);

        (
            uint256 offerId,
            uint256 lenderPos,
            uint256 borrowerPosA,
            bytes32 lenderKey,
            bytes32 borrowerKeyA
        ) = _postTrancheOffer(lenderOwner, borrowerA, lenderPrincipal, borrowerPrincipal, principal, trancheAmount, false);

        uint256 borrowerPosB = nft.mint(borrowerB, COLLATERAL_POOL);
        _finalizeMinter();
        bytes32 borrowerKeyB = nft.getPositionKey(borrowerPosB);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKeyB, borrowerPrincipal, true);

        vm.prank(borrowerA);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPosA);
        assertGt(agreementId, 0, "first acceptance created agreement");
        assertEq(views.trancheRemaining(offerId), 0, "tranche consumed");

        vm.expectRevert();
        vm.prank(borrowerB);
        agreements.acceptOffer(offerId, borrowerPosB);

        assertEq(views.trancheRemaining(offerId), 0, "tranche remains zeroed");
        vm.expectRevert();
        agreements.acceptOffer(offerId, borrowerPosA);
    }
}

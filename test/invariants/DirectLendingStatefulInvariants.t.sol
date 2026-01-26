// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    DirectDiamondTestBase,
    IDirectOffer,
    IDirectAgreement,
    IDirectLifecycle,
    IDirectTestView
} from "../equallend-direct/DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract DirectLendingStatefulHandler is Test {
    IDirectOffer internal offers;
    IDirectAgreement internal agreements;
    IDirectLifecycle internal lifecycle;
    IDirectTestView internal views;
    MockERC20 internal borrowAsset;
    MockERC20 internal collateralAsset;

    address internal lenderOwner;
    address internal borrowerOwner;
    address internal recoverer;

    uint256 internal lenderPos;
    uint256 internal borrowerPos;
    bytes32 internal lenderKey;
    bytes32 internal borrowerKey;

    uint256 internal lenderPoolId;
    uint256 internal collateralPoolId;

    uint256 public offerId;
    uint256 public agreementId;

    constructor(
        IDirectOffer offers_,
        IDirectAgreement agreements_,
        IDirectLifecycle lifecycle_,
        IDirectTestView views_,
        MockERC20 borrowAsset_,
        MockERC20 collateralAsset_,
        address lenderOwner_,
        address borrowerOwner_,
        address recoverer_,
        uint256 lenderPos_,
        uint256 borrowerPos_,
        bytes32 lenderKey_,
        bytes32 borrowerKey_,
        uint256 lenderPoolId_,
        uint256 collateralPoolId_
    ) {
        offers = offers_;
        agreements = agreements_;
        lifecycle = lifecycle_;
        views = views_;
        borrowAsset = borrowAsset_;
        collateralAsset = collateralAsset_;
        lenderOwner = lenderOwner_;
        borrowerOwner = borrowerOwner_;
        recoverer = recoverer_;
        lenderPos = lenderPos_;
        borrowerPos = borrowerPos_;
        lenderKey = lenderKey_;
        borrowerKey = borrowerKey_;
        lenderPoolId = lenderPoolId_;
        collateralPoolId = collateralPoolId_;
    }

    function postOffer(uint256 principalSeed, uint256 collateralSeed, uint256 durationSeed) external {
        if (offerId != 0 || agreementId != 0) {
            return;
        }
        uint256 lenderPrincipal = views.getUserPrincipal(lenderPoolId, lenderKey);
        uint256 lenderTracked = views.getTrackedBalance(lenderPoolId);
        if (lenderPrincipal == 0 || lenderTracked == 0) {
            return;
        }
        uint256 maxPrincipal = lenderPrincipal / 2;
        if (maxPrincipal == 0) {
            return;
        }
        uint256 principal = bound(principalSeed, 1 ether, maxPrincipal);
        if (principal > lenderTracked) {
            return;
        }

        uint256 borrowerPrincipal = views.getUserPrincipal(collateralPoolId, borrowerKey);
        if (borrowerPrincipal == 0) {
            return;
        }
        uint256 maxCollateral = (borrowerPrincipal * 8000) / 10_000;
        if (maxCollateral == 0) {
            return;
        }
        uint256 collateralLock = bound(collateralSeed, 1 ether, maxCollateral);

        uint64 durationSeconds = uint64(bound(durationSeed, 1 days, 5 days));

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: lenderPoolId,
            collateralPoolId: collateralPoolId,
            collateralAsset: address(collateralAsset),
            borrowAsset: address(borrowAsset),
            principal: principal,
            aprBps: 1000,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLock,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        offerId = offers.postOffer(params);
    }

    function acceptOffer() external {
        if (offerId == 0 || agreementId != 0) {
            return;
        }
        vm.prank(borrowerOwner);
        agreementId = agreements.acceptOffer(offerId, borrowerPos);
        if (agreementId != 0) {
            offerId = 0;
        }
    }

    function repay() external {
        if (agreementId == 0) {
            return;
        }
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        if (agreement.status != DirectTypes.DirectStatus.Active) {
            agreementId = 0;
            return;
        }
        if (borrowAsset.balanceOf(borrowerOwner) < agreement.principal) {
            borrowAsset.mint(borrowerOwner, agreement.principal);
        }
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);
        agreementId = 0;
    }

    function recover() external {
        if (agreementId == 0) {
            return;
        }
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        if (agreement.status != DirectTypes.DirectStatus.Active) {
            agreementId = 0;
            return;
        }
        if (block.timestamp < agreement.dueTimestamp + 1 days) {
            return;
        }
        vm.prank(recoverer);
        lifecycle.recover(agreementId);
        agreementId = 0;
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1 days, 10 days);
        vm.warp(block.timestamp + delta);
    }
}

contract DirectLendingStatefulInvariantTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal recoverer = address(0xC0FFEE);

    uint256 internal lenderPos;
    uint256 internal borrowerPos;
    bytes32 internal lenderKey;
    bytes32 internal borrowerKey;

    DirectLendingStatefulHandler internal handler;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();

        tokenA = new MockERC20("Token A", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 2_000_000 ether);

        lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(address(0), 0);
        harness.setActiveCreditShare(0);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, 200 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        tokenB.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);

        handler = new DirectLendingStatefulHandler(
            offers,
            agreements,
            lifecycle,
            views,
            tokenA,
            tokenB,
            lenderOwner,
            borrowerOwner,
            recoverer,
            lenderPos,
            borrowerPos,
            lenderKey,
            borrowerKey,
            LENDER_POOL,
            COLLATERAL_POOL
        );
        targetContract(address(handler));
    }

    function invariant_directBalancesMatchStatus() public {
        (uint256 borrowerLocked,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        (, uint256 lenderLent) = views.getPositionDirectState(lenderPos, LENDER_POOL);

        uint256 agreementId = handler.agreementId();
        uint256 offerId = handler.offerId();
        if (agreementId == 0) {
            assertEq(borrowerLocked, 0, "borrower locked without agreement");
            if (offerId == 0) {
                assertEq(lenderLent, 0, "lender lent without agreement");
            } else {
                assertGt(lenderLent, 0, "offer escrow not reflected in lent");
            }
            return;
        }

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(DirectTypes.DirectStatus.Active), "agreement not active");
        assertGt(borrowerLocked, 0, "active agreement not locked");
        assertGt(lenderLent, 0, "active agreement not lent");
    }
}

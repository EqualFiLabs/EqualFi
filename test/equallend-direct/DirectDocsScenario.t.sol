// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

/// @notice Doc-driven integration fixture for borrower/underwriter negotiation and settlement paths.
contract DirectDocsScenarioTest is DirectDiamondTestBase {
    MockERC20 internal tokenA; // borrow asset
    MockERC20 internal tokenB; // collateral asset

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xFEE1);
    uint16 internal treasurySplitBps;
    uint16 internal activeSplitBps;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    event DirectOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address lender,
        uint256 lenderPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount,
        bool isTranche,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 fillsRemaining,
        uint256 maxFills,
        bool isDepleted
    );

    event DirectOfferLocator(
        address indexed lender,
        uint256 indexed lenderPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    event DirectOfferCancelled(
        uint256 indexed offerId,
        address indexed lender,
        uint256 indexed lenderPositionId,
        DirectTypes.DirectCancelReason reason,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 amountReturned,
        uint256 fillsRemaining,
        bool isDepleted
    );

    event DirectOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId,
        uint256 principalFilled,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 fillsRemaining,
        bool isDepleted
    );

    event DirectAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 principalRepaid);

    event BorrowerOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address borrower,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount
    );

    event BorrowerOfferLocator(
        address indexed borrower,
        uint256 indexed borrowerPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    event BorrowerOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, uint256 indexed lenderPositionId);

    event DirectAgreementExercised(uint256 indexed agreementId, address indexed borrower);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 2_000_000 ether);

        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 500,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 5000,
                defaultLenderBps: 8000,
                minInterestDuration: 0
            })
        );
        treasurySplitBps = DirectTestUtils.treasurySplitFromLegacy(5000, 2000);
        activeSplitBps = DirectTestUtils.activeSplitFromLegacy(5000, 0);
        harness.setTreasuryShare(protocolTreasury, treasurySplitBps);
        harness.setActiveCreditShare(activeSplitBps);
    }

    function _finalizeDiamondMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testDocs_LenderOfferWithPrepayFlow() public {
        vm.warp(10 days);
        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, 300 ether, true);

        tokenA.transfer(borrowerOwner, 200 ether);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 1500,
            durationSeconds: 7 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        uint256 expectedOfferId = 1; // first direct offer uses pre-incremented counter
        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectOfferPosted(
            expectedOfferId,
            params.borrowAsset,
            params.collateralPoolId,
            lenderOwner,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.aprBps,
            params.durationSeconds,
            params.collateralLockAmount,
            false,
            0,
            0,
            1,
            1,
            false
        );
        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectOfferLocator(
            lenderOwner, params.lenderPositionId, expectedOfferId, params.lenderPoolId, params.collateralPoolId
        );
        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        uint256 borrowerBalanceBefore = tokenA.balanceOf(borrowerOwner);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(LENDER_POOL, lenderKey);
        uint256 activeBefore = views.getActiveDirectLent(LENDER_POOL);
        (uint256 lockedBefore,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        assertEq(lockedBefore, 0, "no collateral locked pre-accept");

        uint256 expectedAgreementId = 1;
        vm.expectEmit(true, false, true, true, address(diamond));
        emit DirectOfferAccepted(offerId, expectedAgreementId, borrowerPos, params.principal, 0, 0, 0, true);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        (uint256 lockedAfter, uint256 borrowerLentAfter) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        (, uint256 lenderLentAfter) = views.getPositionDirectState(lenderPos, LENDER_POOL);
        assertEq(lockedAfter, params.collateralLockAmount, "collateral locked on accept");
        assertEq(borrowerLentAfter, 0, "borrower debt tracked in lender pool only");
        assertEq(lenderLentAfter, params.principal, "lender lent tracked");
        assertEq(
            views.getUserPrincipal(LENDER_POOL, lenderKey),
            lenderPrincipalBefore - params.principal,
            "lender principal debited in lender pool"
        );
        assertEq(
            views.getActiveDirectLent(LENDER_POOL),
            activeBefore + params.principal,
            "pool active exposure updated"
        );

        uint256 platformFee = (params.principal * 500) / 10_000;
        uint256 interest = DirectTestUtils.annualizedInterest(params);
        uint256 netBorrowed = params.principal - platformFee - interest;
        assertEq(
            tokenA.balanceOf(borrowerOwner) - borrowerBalanceBefore,
            netBorrowed,
            "borrower receives net principal after upfront fees"
        );

        vm.warp(block.timestamp + 1 days); // early repay allowed by flag
        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectAgreementRepaid(agreementId, borrowerOwner, params.principal);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        (lockedAfter, borrowerLentAfter) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        (, lenderLentAfter) = views.getPositionDirectState(lenderPos, LENDER_POOL);
        assertEq(lockedAfter, 0, "collateral released after repay");
        assertEq(borrowerLentAfter, 0, "borrower debt cleared");
        assertEq(lenderLentAfter, 0, "lender lent cleared");
        assertEq(views.getUserPrincipal(LENDER_POOL, lenderKey), lenderPrincipalBefore, "lender principal restored");
        assertEq(views.getActiveDirectLent(LENDER_POOL), activeBefore, "active lent cleared");
        assertEq(
            uint256(views.getAgreement(agreementId).status),
            uint256(DirectTypes.DirectStatus.Repaid),
            "agreement in repaid status"
        );
    }

    function testDocs_BorrowerOfferExerciseFlow() public {
        vm.warp(20 days);
        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 400 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, 250 ether, true);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 90 ether,
            aprBps: 1200,
            durationSeconds: 5 days,
            collateralLockAmount: 70 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        uint256 expectedBorrowerOfferId = 1; // first borrower offer uses pre-incremented counter
        vm.expectEmit(true, true, true, true, address(diamond));
        emit BorrowerOfferPosted(
            expectedBorrowerOfferId,
            params.borrowAsset,
            params.collateralPoolId,
            borrowerOwner,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.aprBps,
            params.durationSeconds,
            params.collateralLockAmount
        );
        vm.expectEmit(true, true, true, true, address(diamond));
        emit BorrowerOfferLocator(
            borrowerOwner, params.borrowerPositionId, expectedBorrowerOfferId, params.lenderPoolId, params.collateralPoolId
        );
        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerOffer(params);

        (uint256 lockedAfterPost,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        assertEq(lockedAfterPost, params.collateralLockAmount, "collateral locked on posting borrower offer");

        uint256 lenderPrincipalBefore = views.getUserPrincipal(LENDER_POOL, lenderKey);
        uint256 borrowerCollateralBefore = views.getUserPrincipal(COLLATERAL_POOL, borrowerKey);
        uint256 lenderCollateralBefore = views.getUserPrincipal(COLLATERAL_POOL, lenderKey);
        uint256 protocolCollateralBefore = views.getUserPrincipal(COLLATERAL_POOL, LibPositionHelpers.systemPositionKey(protocolTreasury));

        uint256 expectedAgreementId = 1;
        vm.expectEmit(true, false, true, true, address(diamond));
        emit BorrowerOfferAccepted(offerId, expectedAgreementId, lenderPos);
        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerOffer(offerId, lenderPos);

        (, uint256 lenderLentAfter) = views.getPositionDirectState(lenderPos, LENDER_POOL);
        assertEq(lenderLentAfter, params.principal, "lender lent recorded after accept");
        assertEq(
            views.getUserPrincipal(LENDER_POOL, lenderKey),
            lenderPrincipalBefore - params.principal,
            "lender principal debited in lender pool"
        );

        vm.warp(block.timestamp + 1 days); // before maturity, exercise path available
        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectAgreementExercised(agreementId, borrowerOwner);
        vm.prank(borrowerOwner);
        lifecycle.exerciseDirect(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(DirectTypes.DirectStatus.Exercised), "agreement exercised");

        (uint256 borrowerLockedAfter,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        (, lenderLentAfter) = views.getPositionDirectState(lenderPos, LENDER_POOL);
        assertEq(borrowerLockedAfter, 0, "collateral lock cleared after exercise");
        assertEq(lenderLentAfter, 0, "lender lent cleared after exercise");

        uint256 lenderCollateralAfter = views.getUserPrincipal(COLLATERAL_POOL, lenderKey);
        uint256 protocolCollateralAfter = views.getUserPrincipal(COLLATERAL_POOL, LibPositionHelpers.systemPositionKey(protocolTreasury));
        uint256 borrowerCollateralAfter = views.getUserPrincipal(COLLATERAL_POOL, borrowerKey);

        uint256 lenderShare = (params.collateralLockAmount * 8000) / 10_000;
        uint256 remainder = params.collateralLockAmount - lenderShare;
        (uint256 protocolShare,, uint256 feeIndexShare) =
            DirectTestUtils.previewSplit(remainder, treasurySplitBps, activeSplitBps, true);

        assertEq(
            lenderCollateralAfter - lenderCollateralBefore,
            lenderShare,
            "lender receives documented collateral share"
        );
        assertEq(
            protocolCollateralAfter - protocolCollateralBefore,
            protocolShare,
            "protocol share credited in collateral pool"
        );
        assertEq(
            borrowerCollateralAfter,
            borrowerCollateralBefore >= params.collateralLockAmount
                ? borrowerCollateralBefore - params.collateralLockAmount
                : 0,
            "borrower loses locked portion"
        );
        assertEq(
            views.getUserPrincipal(LENDER_POOL, lenderKey),
            lenderPrincipalBefore - params.principal,
            "lender principal remains debited in lender pool"
        );
    }
}

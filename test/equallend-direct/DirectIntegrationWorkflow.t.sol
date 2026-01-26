// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

/// @notice Integration workflow tests: post→accept→repay and post→accept→recover
contract DirectIntegrationWorkflowTest is DirectDiamondTestBase {
    MockERC20 internal tokenA; // lender underlying / borrow asset
    MockERC20 internal tokenB; // borrower underlying / collateral asset

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    address internal thirdParty = address(0xC0FFEE);
    uint16 internal treasurySplitBps;
    uint16 internal activeSplitBps;

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        treasurySplitBps = DirectTestUtils.treasurySplitFromLegacy(5000, 2000);
        activeSplitBps = DirectTestUtils.activeSplitFromLegacy(5000, 0);
        harness.setTreasuryShare(protocolTreasury, treasurySplitBps);
        harness.setActiveCreditShare(activeSplitBps);
    }

    function testIntegration_EndToEndRepayAndRecover() public {
        vm.warp(10 days);
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(tokenA), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(tokenB), borrowerKey, 200 ether, true);

        // Fund balances and approvals
        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 100 ether);
        tokenB.transfer(lenderOwner, 100 ether);
        tokenB.transfer(borrowerOwner, 150 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);

        // Offer 1 → repay flow
        DirectTypes.DirectOfferParams memory offerRepay = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 80 ether,
            aprBps: 1200,
            durationSeconds: 3 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerIdRepay = offers.postOffer(offerRepay);
        vm.prank(borrowerOwner);
        uint256 agreementRepayId = agreements.acceptOffer(offerIdRepay, borrowerPos);

        (uint256 borrowerLocked, uint256 borrowerLent) = views.getPositionDirectState(borrowerPos, 2);
        assertEq(borrowerLocked, offerRepay.collateralLockAmount, "collateral locked");
        assertEq(borrowerLent, 0);
        (, uint256 lenderLent) = views.getPositionDirectState(lenderPos, 1);
        assertEq(lenderLent, offerRepay.principal, "lender lent tracked");

        // Repay principal only
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementRepayId);
        (borrowerLocked, borrowerLent) = views.getPositionDirectState(borrowerPos, 2);
        (, lenderLent) = views.getPositionDirectState(lenderPos, 1);
        assertEq(borrowerLocked, 0, "collateral unlocked on repay");
        assertEq(lenderLent, 0, "lender lent cleared on repay");
        assertEq(
            uint256(views.getAgreement(agreementRepayId).status),
            uint256(DirectTypes.DirectStatus.Repaid),
            "repay status"
        );

        // Offer 2 → default/recover flow (cross-pool collateral still pool 2)
        DirectTypes.DirectOfferParams memory offerDefault = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 60 ether,
            aprBps: 1000,
            durationSeconds: 1 days,
            collateralLockAmount: 40 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerIdDefault = offers.postOffer(offerDefault);
        vm.prank(borrowerOwner);
        uint256 agreementDefaultId = agreements.acceptOffer(offerIdDefault, borrowerPos);
        uint256 defaultAcceptedAt = block.timestamp;

        vm.warp(DirectTestUtils.dueTimestamp(defaultAcceptedAt, offerDefault.durationSeconds) + 1 days);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(1, lenderKey);
        uint256 borrowerPrincipalBefore = views.getUserPrincipal(2, borrowerKey);
        uint256 lenderPrincipalCollateralBefore = views.getUserPrincipal(2, lenderKey);
        uint256 protocolPrincipalCollateralBefore = views.getUserPrincipal(2, LibPositionHelpers.systemPositionKey(protocolTreasury));

        vm.prank(thirdParty);
        lifecycle.recover(agreementDefaultId);

        DirectTypes.DirectAgreement memory defaultAgreement = views.getAgreement(agreementDefaultId);
        assertEq(
            uint256(defaultAgreement.status),
            uint256(DirectTypes.DirectStatus.Defaulted),
            "defaulted status"
        );

        uint256 borrowerPrincipalAfter = views.getUserPrincipal(2, borrowerKey);
        uint256 collateralUsed = offerDefault.collateralLockAmount;
        uint256 lenderShare = (collateralUsed * 8000) / 10_000;
        uint256 remainder = collateralUsed - lenderShare;
        (uint256 protocolShare,, uint256 feeIndexShare) =
            DirectTestUtils.previewSplit(remainder, treasurySplitBps, activeSplitBps, true);

        assertEq(views.getUserPrincipal(1, lenderKey), lenderPrincipalBefore, "lender principal unchanged after default");
        uint256 expectedBorrower = borrowerPrincipalBefore > collateralUsed ? borrowerPrincipalBefore - collateralUsed : 0;
        assertEq(borrowerPrincipalAfter, expectedBorrower, "borrower collateral deducted");
        assertEq(views.getUserPrincipal(2, lenderKey), lenderPrincipalCollateralBefore + lenderShare, "lender credited in collateral pool");
        assertEq(views.getUserPrincipal(2, LibPositionHelpers.systemPositionKey(protocolTreasury)), protocolPrincipalCollateralBefore + protocolShare, "protocol credited in collateral pool");

        (borrowerLocked, borrowerLent) = views.getPositionDirectState(borrowerPos, 2);
        (, lenderLent) = views.getPositionDirectState(lenderPos, 1);
        assertEq(borrowerLocked, 0, "locked cleared after recover");
        assertEq(lenderLent, 0, "lent cleared after recover");
    }

    /// @dev Deterministic happy-path for gas reporting: post → accept → repay.
    function test_gas_DirectOfferRepayFlow() public {
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(tokenA), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(tokenB), borrowerKey, 150 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.transfer(borrowerOwner, 200 ether);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory offerRepay = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 50 ether,
            aprBps: 1200,
            durationSeconds: 3 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(offerRepay);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);
    }
}

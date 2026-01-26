// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_GracePeriodActive} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 11: Recovery timing and permissions
/// @notice Validates: Requirements 4.1, 4.6
contract DirectRecoveryPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 0,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 0,
                defaultLenderBps: 7000,
                minInterestDuration: 0
            })
        );
        harness.setTreasuryShare(protocolTreasury, 3334);
        harness.setActiveCreditShare(0);
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_RecoveryTimingAndPermissions() public {
        DirectTypes.DirectConfig memory cfg = views.getDirectConfig();
        assertEq(cfg.defaultLenderBps, 7000, "config default lender share");
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 20 ether, true); // undercollateralized vs lock

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 50 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 800,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        uint256 acceptTimestamp = block.timestamp;

        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(DirectTestUtils.dueTimestamp(acceptTimestamp, params.durationSeconds) + 1 days);
        (uint256 totalDepositsBefore, uint256 feeIndexBefore) = views.poolTotals(2);
        (uint256 trackedBefore,) = views.poolTracked(2);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(1, lenderKey);
        uint256 borrowerPrincipalBefore = views.getUserPrincipal(2, borrowerKey);
        uint256 protocolPrincipalBefore = views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury));

        vm.prank(stranger);
        lifecycle.recover(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Defaulted), "status defaulted");

        uint256 collateralAvailable = borrowerPrincipalBefore >= params.collateralLockAmount
            ? params.collateralLockAmount
            : borrowerPrincipalBefore;
        uint256 lenderShare = (collateralAvailable * cfg.defaultLenderBps) / 10_000;
        uint256 remainder = collateralAvailable > lenderShare ? collateralAvailable - lenderShare : 0;
        (uint256 protocolShare, uint256 activeShare, uint256 feeIndexShare) =
            DirectTestUtils.previewSplit(remainder, 3334, 0, true);

        uint256 lenderDelta = views.getUserPrincipal(1, lenderKey) - lenderPrincipalBefore;
        uint256 protocolDelta = views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury)) - protocolPrincipalBefore;
        (uint256 trackedAfter,) = views.poolTracked(2);
        (uint256 totalDepositsAfter, uint256 feeIndexAfter) = views.poolTotals(2);
        uint256 totalOut = totalDepositsBefore - totalDepositsAfter;
        uint256 retainedForFeeIndex = totalOut > lenderDelta + protocolDelta
            ? totalOut - (lenderDelta + protocolDelta)
            : 0;
        assertApproxEqAbs(retainedForFeeIndex, feeIndexShare, 1, "fee index retention");
        assertGt(lenderDelta, 0, "lender received share");
        assertGt(protocolDelta, 0, "protocol received share");
        assertEq(
            views.getUserPrincipal(2, borrowerKey),
            borrowerPrincipalBefore - collateralAvailable,
            "borrower collateral deducted"
        );
        assertEq(trackedAfter, trackedBefore - lenderShare - protocolShare + activeShare, "tracked reduced");
        assertEq(
            totalDepositsAfter,
            totalDepositsBefore - collateralAvailable,
            "total deposits reduced by seized collateral"
        );

        uint256 expectedDelta = collateralAvailable == 0
            ? 0
            : (feeIndexShare * 1e18) / (totalDepositsBefore - collateralAvailable);
        assertEq(feeIndexAfter, feeIndexBefore + expectedDelta, "fee index accrues");
    }
}

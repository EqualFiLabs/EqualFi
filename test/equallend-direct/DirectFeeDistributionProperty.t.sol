// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: equallend-direct, Property 3: Fee distribution accuracy
/// @notice Validates: Requirements 2.3, 2.5, 2.6, 4.2, 4.4, 8.1, 8.2
contract DirectFeeDistributionPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);
        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 500, // 5%
                interestLenderBps: 10_000,
                platformFeeLenderBps: 5000,
                defaultLenderBps: 10_000,
                minInterestDuration: 0
            })
        );
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _finalizeDiamondMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_FeeDistributionAccuracy() public {
        vm.warp(30 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);
        harness.setTotalDeposits(2, 200 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        asset.transfer(lenderOwner, 200 ether);
        asset.transfer(borrowerOwner, 50 ether);

        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        uint256 lenderBefore = asset.balanceOf(lenderOwner);
        uint256 borrowerBefore = asset.balanceOf(borrowerOwner);
        uint256 protocolBefore = asset.balanceOf(protocolTreasury);
        uint256 contractBefore = asset.balanceOf(address(diamond));
        (uint256 totalDeposits, uint256 feeIndexBefore) = views.poolTotals(2);
        assertEq(totalDeposits, 200 ether, "seeded total deposits");

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPositionId);

        uint256 interest = DirectTestUtils.annualizedInterest(params);
        uint256 platformFee = (params.principal * 500) / 10_000; // 5 ether
        uint256 lenderShare = interest + (platformFee * 5000) / 10_000;
        uint256 feeIndexShare = (platformFee * 3000) / 10_000; // 1.5
        uint256 activeCreditShare = (platformFee * 0) / 10_000;
        uint256 protocolShare = platformFee - (platformFee * 5000) / 10_000 - feeIndexShare - activeCreditShare; // 1
        uint256 expectedFeeIndexDelta = (feeIndexShare * 1e18) / totalDeposits;

        assertEq(asset.balanceOf(lenderOwner), lenderBefore, "lender balance unchanged (yield to position)");
        assertEq(views.accruedYield(1, lenderKey), lenderShare, "lender yield credited");
        assertEq(
            asset.balanceOf(borrowerOwner),
            borrowerBefore + params.principal - (interest + platformFee),
            "borrower net"
        );
        assertEq(asset.balanceOf(protocolTreasury), protocolBefore + protocolShare, "protocol share");
        assertEq(
            asset.balanceOf(address(diamond)),
            contractBefore - params.principal + lenderShare + feeIndexShare + activeCreditShare,
            "fee index retained on contract"
        );
        (, uint256 feeIndexAfter) = views.poolTotals(2);
        assertEq(feeIndexAfter, feeIndexBefore + expectedFeeIndexDelta, "fee index accrued");

        (uint256 locked, uint256 lent) = views.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(locked, params.collateralLockAmount);
        assertEq(lent, 0);
    }

    function test_acceptOffer_doesNotRequireBorrowerAllowance() public {
        vm.warp(30 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        uint256 borrowerBefore = asset.balanceOf(borrowerOwner);

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPositionId);

        uint256 interest = DirectTestUtils.annualizedInterest(params);
        uint256 platformFee = (params.principal * 500) / 10_000;
        uint256 expectedNet = params.principal - (interest + platformFee);

        assertEq(asset.balanceOf(borrowerOwner), borrowerBefore + expectedNet, "borrower net");
    }

    function test_acceptBorrowerOffer_doesNotRequireBorrowerAllowance() public {
        vm.warp(30 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerOffer(params);

        uint256 borrowerBefore = asset.balanceOf(borrowerOwner);

        vm.prank(lenderOwner);
        agreements.acceptBorrowerOffer(offerId, lenderPositionId);

        uint256 interest = DirectTestUtils.annualizedInterest(
            DirectTypes.DirectOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                collateralAsset: address(asset),
                borrowAsset: address(asset),
                principal: params.principal,
                aprBps: params.aprBps,
                durationSeconds: params.durationSeconds,
                collateralLockAmount: params.collateralLockAmount,
                allowEarlyRepay: false,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        uint256 platformFee = (params.principal * 500) / 10_000;
        uint256 expectedNet = params.principal - (interest + platformFee);

        assertEq(asset.balanceOf(borrowerOwner), borrowerBefore + expectedNet, "borrower net");
    }
}

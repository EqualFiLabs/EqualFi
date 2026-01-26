// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 6: Fee consistency across settlement paths
/// @notice Validates: Requirements 5.1, 5.2, 5.3, 5.5, 2.5
contract DirectFeeConsistencyPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 7000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(7000, 1000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(7000, 0));
    }

    function testProperty_FeeConsistencyAcrossSettlementPaths() public {
        vm.warp(200 days);
        uint256 lenderPositionA = nft.mint(address(0xA11CE), 1);
        uint256 borrowerPositionA = nft.mint(address(0xB0B), 2);
        uint256 lenderPositionB = nft.mint(address(0xA11CE2), 3);
        uint256 borrowerPositionB = nft.mint(address(0xB0B2), 4);
        finalizePositionNFT();

        bytes32 lenderKeyA = nft.getPositionKey(lenderPositionA);
        bytes32 borrowerKeyA = nft.getPositionKey(borrowerPositionA);
        bytes32 lenderKeyB = nft.getPositionKey(lenderPositionB);
        bytes32 borrowerKeyB = nft.getPositionKey(borrowerPositionB);

        harness.seedPoolWithMembership(1, address(asset), lenderKeyA, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKeyA, 30 ether, true);
        harness.seedPoolWithMembership(3, address(asset), lenderKeyB, 500 ether, true);
        harness.seedPoolWithMembership(4, address(asset), borrowerKeyB, 30 ether, true);

        asset.transfer(address(0xA11CE), 500 ether);
        asset.transfer(address(0xB0B), 200 ether);
        asset.transfer(address(0xA11CE2), 500 ether);
        asset.transfer(address(0xB0B2), 200 ether);

        vm.prank(address(0xA11CE));
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(address(0xB0B));
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(address(0xA11CE2));
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(address(0xB0B2));
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionA,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 800,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.prank(address(0xA11CE));
        uint256 offerA = offers.postOffer(params);
        vm.prank(address(0xB0B));
        uint256 agreementA = agreements.acceptOffer(offerA, borrowerPositionA);
        uint256 borrowerBalanceA = asset.balanceOf(address(0xB0B));

        uint256 lenderPrincipalBeforeA = views.getUserPrincipal(1, lenderKeyA);
        uint256 protocolPrincipalBeforeA = views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury));
        uint256 feeIndexBeforeA = views.getFeeIndex(2);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(0xB0B));
        lifecycle.exerciseDirect(agreementA);

        uint256 lenderDeltaA = views.getUserPrincipal(1, lenderKeyA) - lenderPrincipalBeforeA;
        uint256 protocolDeltaA = views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury)) - protocolPrincipalBeforeA;
        uint256 feeIndexDeltaA = views.getFeeIndex(2) - feeIndexBeforeA;
        uint256 borrowerBalanceAfterA = asset.balanceOf(address(0xB0B));
        assertEq(borrowerBalanceAfterA, borrowerBalanceA, "exercise premium unchanged");

        DirectTypes.DirectOfferParams memory paramsB = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionB,
            lenderPoolId: 3,
            collateralPoolId: 4,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 800,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(address(0xA11CE2));
        uint256 offerB = offers.postOffer(paramsB);
        vm.prank(address(0xB0B2));
        uint256 agreementB = agreements.acceptOffer(offerB, borrowerPositionB);
        uint256 borrowerBalanceB = asset.balanceOf(address(0xB0B2));

        uint256 lenderPrincipalBeforeB = views.getUserPrincipal(3, lenderKeyB);
        uint256 protocolPrincipalBeforeB = views.getUserPrincipal(3, LibPositionHelpers.systemPositionKey(protocolTreasury));
        uint256 feeIndexBeforeB = views.getFeeIndex(4);

        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(block.timestamp, paramsB.durationSeconds);
        vm.warp(dueTimestamp + 1 days);
        lifecycle.recover(agreementB);

        uint256 lenderDeltaB = views.getUserPrincipal(3, lenderKeyB) - lenderPrincipalBeforeB;
        uint256 protocolDeltaB = views.getUserPrincipal(3, LibPositionHelpers.systemPositionKey(protocolTreasury)) - protocolPrincipalBeforeB;
        uint256 feeIndexDeltaB = views.getFeeIndex(4) - feeIndexBeforeB;
        uint256 borrowerBalanceAfterB = asset.balanceOf(address(0xB0B2));
        assertEq(borrowerBalanceAfterB, borrowerBalanceB, "recover premium unchanged");

        assertEq(lenderDeltaA, lenderDeltaB, "lender share consistent");
        assertEq(protocolDeltaA, protocolDeltaB, "protocol share consistent");
        assertEq(feeIndexDeltaA, feeIndexDeltaB, "fee index consistent");
    }
}

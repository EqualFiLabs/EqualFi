// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_GracePeriodActive} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 9: Grace period enforcement
/// @notice Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5
contract DirectGracePeriodPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    address internal stranger = address(0xCAFE);

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

    function testProperty_GracePeriodEnforcement() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 20 ether, true);

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
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        uint256 acceptTimestamp = block.timestamp;
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, params.durationSeconds);

        vm.warp(dueTimestamp);
        vm.prank(stranger);
        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(dueTimestamp + 1 days - 1);
        vm.prank(stranger);
        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(dueTimestamp + 1 days);
        vm.prank(stranger);
        lifecycle.recover(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Defaulted), "status defaulted");
    }
}

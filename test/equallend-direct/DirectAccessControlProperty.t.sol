// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 7: Access control enforcement
/// @notice Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5
contract DirectAccessControlPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal operator = address(0x0B0);
    address internal stranger = address(0xCAFE);
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

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_AccessControlEnforcement() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 30 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 200 ether);
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
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, borrowerPositionId));
        lifecycle.repay(agreementId);

        vm.prank(borrowerOwner);
        nft.approve(operator, borrowerPositionId);
        vm.prank(borrowerOwner);
        asset.transfer(operator, 100 ether);
        vm.prank(operator);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(operator);
        lifecycle.repay(agreementId);

        vm.prank(lenderOwner);
        uint256 offerIdExercise =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        vm.prank(borrowerOwner);
        uint256 agreementIdExercise = agreements.acceptOffer(offerIdExercise, borrowerPositionId);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, borrowerPositionId));
        lifecycle.exerciseDirect(agreementIdExercise);

        vm.prank(operator);
        lifecycle.exerciseDirect(agreementIdExercise);

        DirectTypes.DirectOfferParams memory recoverParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerIdRecover = offers.postOffer(
            recoverParams, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0})
        );
        vm.prank(borrowerOwner);
        uint256 agreementIdRecover = agreements.acceptOffer(offerIdRecover, borrowerPositionId);

        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(block.timestamp, recoverParams.durationSeconds);
        vm.warp(dueTimestamp + 1 days);
        vm.prank(stranger);
        lifecycle.recover(agreementIdRecover);
    }
}

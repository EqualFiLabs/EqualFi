// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodActive,
    DirectError_GracePeriodExpired,
    DirectError_InvalidAgreementState,
    DirectError_InvalidTimestamp
} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

contract DirectEdgeCaseTests is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal operator = address(0x0B0);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(8000, 1000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(8000, 0));
    }

    function _setupOffer(bool allowEarlyRepay, bool allowEarlyExercise)
        internal
        returns (uint256 agreementId, uint256 borrowerPositionId, uint256 acceptTimestamp)
    {
        vm.warp(100 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        borrowerPositionId = nft.mint(borrowerOwner, 2);
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

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
            allowEarlyRepay: allowEarlyRepay,
            allowEarlyExercise: allowEarlyExercise,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        acceptTimestamp = block.timestamp;
    }

    function testEdge_TimingBoundariesRepay() public {
        (uint256 agreementId,, uint256 acceptTimestamp) = _setupOffer(false, false);
        finalizePositionNFT();
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);

        vm.warp(dueTimestamp - 1 days - 1);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        lifecycle.repay(agreementId);

        vm.warp(dueTimestamp - 1 days);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);
    }

    function testEdge_GracePeriodRepayAndRecover() public {
        (uint256 agreementId,, uint256 acceptTimestamp) = _setupOffer(true, false);
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);

        vm.warp(dueTimestamp + 1 days);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        (agreementId,, acceptTimestamp) = _setupOffer(false, false);
        dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);

        vm.warp(dueTimestamp + 1 days - 1);
        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(dueTimestamp + 1 days);
        lifecycle.recover(agreementId);

        (agreementId,, acceptTimestamp) = _setupOffer(true, false);
        finalizePositionNFT();
        dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);
        vm.warp(dueTimestamp + 1 days + 1);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_GracePeriodExpired.selector);
        lifecycle.repay(agreementId);
    }

    function testEdge_ExerciseTimingAndFlags() public {
        (uint256 agreementId,, uint256 acceptTimestamp) = _setupOffer(false, false);
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);

        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyExerciseNotAllowed.selector);
        lifecycle.exerciseDirect(agreementId);

        // Allow exercise and permit it through grace; only fail after grace expires
        (agreementId,, acceptTimestamp) = _setupOffer(false, true);
        dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);
        vm.warp(dueTimestamp); // at maturity, allowed
        vm.prank(borrowerOwner);
        lifecycle.exerciseDirect(agreementId);

        // New agreement to test post-grace rejection
        (agreementId,, acceptTimestamp) = _setupOffer(false, true);
        finalizePositionNFT();
        dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, 3 days);
        vm.warp(dueTimestamp + 1 days + 1);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_InvalidTimestamp.selector);
        lifecycle.exerciseDirect(agreementId);
    }

    function testEdge_AccessControlOperatorRepay() public {
        (uint256 agreementId, uint256 borrowerPositionId,) = _setupOffer(true, false);
        finalizePositionNFT();

        vm.prank(borrowerOwner);
        nft.approve(operator, borrowerPositionId);
        vm.prank(borrowerOwner);
        asset.transfer(operator, 100 ether);
        vm.prank(operator);
        asset.approve(address(diamond), type(uint256).max);

        vm.prank(operator);
        lifecycle.repay(agreementId);

        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        vm.prank(operator);
        lifecycle.repay(agreementId);
    }

    function testEdge_AccessControlUnauthorizedExercise() public {
        (uint256 agreementId,,) = _setupOffer(false, true);
        finalizePositionNFT();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, operator, 2));
        lifecycle.exerciseDirect(agreementId);
    }
}

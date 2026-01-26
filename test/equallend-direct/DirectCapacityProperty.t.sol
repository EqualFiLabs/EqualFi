// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 2: Capacity management invariant
/// @notice Validates: Requirements 1.2, 2.2, 5.1, 5.2, 5.4
contract DirectCapacityPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
    }

    function testProperty_CapacityManagementInvariant() public {
        vm.warp(5 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 100 ether, true);
        harness.setOfferEscrow(lenderKey, 1, 30 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 20 ether,
            aprBps: 1000,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        assertEq(views.getOffer(offerId).principal, 20 ether);

        (, uint256 lentAfterPost) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lentAfterPost, 50 ether, "direct state includes reserved offer");

        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);
        (, uint256 lentAfterCancel) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lentAfterCancel, 30 ether, "cancel frees reserved capacity");

        DirectTypes.DirectOfferParams memory tooLarge = params;
        tooLarge.principal = 80 ether;
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, tooLarge.principal, 70 ether));
        vm.prank(lenderOwner);
        offers.postOffer(tooLarge);
    }
}

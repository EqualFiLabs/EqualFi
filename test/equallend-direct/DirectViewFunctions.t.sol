// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice View function accuracy and data access
contract DirectViewFunctionsTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(address(0xF00D), DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testViewFunctionsReturnStoredData() public {
        vm.warp(50 days);
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 200 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 150 ether, true);

        asset.transfer(lenderOwner, 300 ether);
        asset.transfer(borrowerOwner, 50 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 80 ether,
            aprBps: 700,
            durationSeconds: 5 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        DirectTypes.DirectOffer memory viewOffer = views.getOffer(offerId);
        assertEq(viewOffer.lender, lenderOwner);
        assertEq(viewOffer.collateralPoolId, 2);
        assertEq(viewOffer.principal, params.principal);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.collateralPoolId, 2);
        assertEq(agreement.collateralAsset, address(asset));
        assertEq(agreement.borrowerPositionId, borrowerPos);

        (uint256 locked, uint256 lent) = views.getPositionDirectState(borrowerPos, params.collateralPoolId);
        assertEq(locked, params.collateralLockAmount);
        assertEq(lent, 0);
    }
}

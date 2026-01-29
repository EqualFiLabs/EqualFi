// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestBase} from "./DirectTestBase.sol";

contract DirectSolvencyFixesTest is DirectTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpBase();
        tokenA = new MockERC20("TokenA", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("TokenB", "TKB", 6, 2_000_000 * 1e6);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        facet.setDirectConfig(cfg);
    }

    function test_acceptOffer_sameAsset_includesNewDebtAndLenderPoolDebt() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        // Same asset, different pools to validate lenderPoolId debt lookup.
        facet.seedPoolWithMembership(1, address(tokenA), lenderKey, 500 ether, true);
        facet.seedPoolWithMembership(2, address(tokenA), borrowerKey, 100 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 100 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(facet), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(facet), type(uint256).max);

        // Existing debt in lender pool brings the borrower close to the LTV edge.
        facet.setDirectState(borrowerKey, lenderKey, 2, 1, 0, 70 ether, 1);

        DirectTypes.DirectOfferParams memory params;
        params.lenderPositionId = lenderPositionId;
        params.lenderPoolId = 1;
        params.collateralPoolId = 2;
        params.collateralAsset = address(tokenA);
        params.borrowAsset = address(tokenA);
        params.principal = 20 ether;
        params.aprBps = 0;
        params.durationSeconds = 1 days;
        params.collateralLockAmount = 10 ether;
        params.allowEarlyRepay = false;
        params.allowEarlyExercise = false;
        params.allowLenderCall = false;

        vm.prank(lenderOwner);
        uint256 offerId = facet.postOffer(params);

        vm.prank(borrowerOwner);
        vm.expectRevert(bytes("SolvencyViolation: Borrower LTV"));
        facet.acceptOffer(offerId, borrowerPositionId);
    }

    function test_acceptOffer_sameAsset_doesNotTreatLockAsDebt() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        facet.seedPoolWithMembership(1, address(tokenA), lenderKey, 500 ether, true);
        facet.seedPoolWithMembership(2, address(tokenA), borrowerKey, 200 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(facet), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(facet), type(uint256).max);

        DirectTypes.DirectOfferParams memory params;
        params.lenderPositionId = lenderPositionId;
        params.lenderPoolId = 1;
        params.collateralPoolId = 2;
        params.collateralAsset = address(tokenA);
        params.borrowAsset = address(tokenA);
        params.principal = 100 ether;
        params.aprBps = 0;
        params.durationSeconds = 1 days;
        params.collateralLockAmount = 150 ether;
        params.allowEarlyRepay = false;
        params.allowEarlyExercise = false;
        params.allowLenderCall = false;

        vm.prank(lenderOwner);
        uint256 offerId = facet.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = facet.acceptOffer(offerId, borrowerPositionId);
        assertGt(agreementId, 0, "agreement created");

        (uint256 locked,) = facet.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(locked, params.collateralLockAmount, "collateral locked");
    }

    function test_acceptOffer_crossAsset_skipsLtv() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        facet.seedPoolWithMembership(1, address(tokenA), lenderKey, 2_000 ether, true);
        facet.seedPoolWithMembership(2, address(tokenB), borrowerKey, 10_000 * 1e6, true);

        tokenA.transfer(lenderOwner, 2_000 ether);
        tokenB.transfer(borrowerOwner, 10_000 * 1e6);
        vm.prank(lenderOwner);
        tokenA.approve(address(facet), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenB.approve(address(facet), type(uint256).max);

        DirectTypes.DirectOfferParams memory params;
        params.lenderPositionId = lenderPositionId;
        params.lenderPoolId = 1;
        params.collateralPoolId = 2;
        params.collateralAsset = address(tokenB);
        params.borrowAsset = address(tokenA);
        params.principal = 1_000 ether;
        params.aprBps = 0;
        params.durationSeconds = 1 days;
        params.collateralLockAmount = 1_000 * 1e6;
        params.allowEarlyRepay = false;
        params.allowEarlyExercise = false;
        params.allowLenderCall = false;

        vm.prank(lenderOwner);
        uint256 offerId = facet.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = facet.acceptOffer(offerId, borrowerPositionId);
        assertGt(agreementId, 0, "agreement created");
    }
}

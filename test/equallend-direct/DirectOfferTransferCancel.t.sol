// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidOffer} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestBase} from "./DirectTestBase.sol";

/// @notice Tests that outstanding offers are cancelled when the lender NFT transfers
contract DirectOfferTransferCancelTest is DirectTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal newOwner = address(0xC0FFEE);

    function setUp() public {
        setUpBase();
        tokenA = new MockERC20("TokenA", "TKA", 18, 1_000_000 ether);
        tokenB = new MockERC20("TokenB", "TKB", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        facet.setConfig(cfg);
    }

    function _seedPositions() internal returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) {
        lenderPos = nft.mint(lender, 1);
        borrowerPos = nft.mint(borrower, 2);
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        facet.seedPoolWithMembership(1, address(tokenA), lenderKey, 200 ether, true);
        facet.seedPoolWithMembership(2, address(tokenB), borrowerKey, 100 ether, true);
    }

    function test_OfferCancelledOnLenderTransfer() public {
        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey,) = _seedPositions();

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lender);
        uint256 offerId = facet.postOffer(params);
        assertEq(facet.offerEscrow(lenderKey, params.lenderPoolId), 50 ether, "escrow tracked on post");

        // Cancel offers before transfer per PositionNFT guard, then transfer lender NFT
        facet.cancelOffersForPosition(lenderPos);
        vm.prank(lender);
        nft.transferFrom(lender, newOwner, lenderPos);

        DirectTypes.DirectOffer memory offer = facet.getOffer(offerId);
        assertTrue(offer.cancelled, "offer cancelled on transfer");
        assertEq(facet.offerEscrow(lenderKey, params.lenderPoolId), 0, "escrow released on cancel");

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(borrower);
        facet.acceptOffer(offerId, borrowerPos);
    }

    function test_MultipleOffersCancelledOnTransfer() public {
        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey,) = _seedPositions();

        DirectTypes.DirectOfferParams memory base = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 20 ether,
            aprBps: 0,
            durationSeconds: 2 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.startPrank(lender);
        uint256 offerOne = facet.postOffer(base);
        base.principal = 30 ether;
        uint256 offerTwo = facet.postOffer(base);
        vm.stopPrank();

        assertEq(facet.offerEscrow(lenderKey, base.lenderPoolId), 50 ether, "aggregate escrow tracked");

        facet.cancelOffersForPosition(lenderPos);
        vm.prank(lender);
        nft.transferFrom(lender, newOwner, lenderPos);

        DirectTypes.DirectOffer memory o1 = facet.getOffer(offerOne);
        DirectTypes.DirectOffer memory o2 = facet.getOffer(offerTwo);
        assertTrue(o1.cancelled && o2.cancelled, "all offers cancelled");
        assertEq(facet.offerEscrow(lenderKey, base.lenderPoolId), 0, "escrow cleared");

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(borrower);
        facet.acceptOffer(offerOne, borrowerPos);
        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(borrower);
        facet.acceptOffer(offerTwo, borrowerPos);
    }
}

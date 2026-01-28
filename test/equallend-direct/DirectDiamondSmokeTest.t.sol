// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Smoke test to verify diamond-based test harness works
contract DirectDiamondSmokeTest is DirectDiamondTestBase {
    MockERC20 internal token;
    address internal lenderOwner = address(0x1111);
    address internal borrowerOwner = address(0x2222);

    uint256 internal lenderPositionId;
    uint256 internal borrowerPositionId;
    bytes32 internal lenderKey;
    bytes32 internal borrowerKey;

    function setUp() public {
        setUpDiamond();

        token = new MockERC20("Test", "TST", 18, 1_000_000 ether);

        // Mint positions (test contract is minter from setUpDiamond)
        lenderPositionId = nft.mint(lenderOwner, 1);
        borrowerPositionId = nft.mint(borrowerOwner, 2);
        lenderKey = nft.getPositionKey(lenderPositionId);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        // Now set diamond as minter and diamond address
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));

        // Seed pools
        harness.seedPoolWithMembership(1, address(token), lenderKey, 1000 ether, true);
        harness.seedPoolWithMembership(2, address(token), borrowerKey, 500 ether, true);

        // Configure direct lending
        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function test_DiamondSetupWorks() public {
        // Verify NFT setup
        assertEq(nft.ownerOf(lenderPositionId), lenderOwner);
        assertEq(nft.ownerOf(borrowerPositionId), borrowerOwner);

        // Verify pool seeding via view facet
        assertTrue(views.isMember(lenderKey, 1));
        assertTrue(views.isMember(borrowerKey, 2));

        // Verify config
        DirectTypes.DirectConfig memory cfg = views.getDirectConfig();
        assertEq(cfg.platformFeeBps, 500);
        assertEq(cfg.platformFeeLenderBps, 10_000);
    }

    function test_PostAndAcceptBorrowerOffer() public {
        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 150 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 offerId = offers.postBorrowerOffer(params);

        // Verify offer stored
        DirectTypes.DirectBorrowerOffer memory offer = views.getBorrowerOffer(offerId);
        assertEq(offer.borrower, borrowerOwner);
        assertEq(offer.principal, 100 ether);
        assertFalse(offer.filled);

        // Accept offer
        vm.prank(lenderOwner);
        uint256 agreementId = agreements.acceptBorrowerOffer(offerId, lenderPositionId);

        // Verify agreement created
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.lender, lenderOwner);
        assertEq(agreement.borrower, borrowerOwner);
        assertEq(agreement.principal, 100 ether);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active));
    }

    function test_PostAndAcceptLenderOffer() public {
        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 150 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory trancheParams = DirectTypes.DirectTrancheOfferParams({
            isTranche: false,
            trancheAmount: 0
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, trancheParams);

        // Verify offer stored
        DirectTypes.DirectOffer memory offer = views.getOffer(offerId);
        assertEq(offer.lender, lenderOwner);
        assertEq(offer.principal, 100 ether);

        // Accept offer
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        // Verify agreement
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.lender, lenderOwner);
        assertEq(agreement.borrower, borrowerOwner);
    }
}

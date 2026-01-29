// SPDX-License-Identifier: MIT
// forge-config: default.optimizer = true
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestBase} from "./DirectTestBase.sol";

contract DirectBorrowerIndexTest is DirectTestBase {
    MockERC20 internal borrowToken;
    MockERC20 internal collToken;
    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);

    struct BorrowerContext {
        uint256 lenderPos;
        uint256 borrowerPos;
        bytes32 lenderKey;
        bytes32 borrowerKey;
    }

    function setUp() public {
        setUpBase();
        borrowToken = new MockERC20("B", "B", 18, 1_000_000 ether);
        collToken = new MockERC20("C", "C", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        facet.setConfig(cfg);
    }

    function _mintPositions() internal returns (BorrowerContext memory ctx) {
        ctx.lenderPos = nft.mint(lender, 1);
        ctx.borrowerPos = nft.mint(borrower, 2);
        ctx.lenderKey = nft.getPositionKey(ctx.lenderPos);
        ctx.borrowerKey = nft.getPositionKey(ctx.borrowerPos);
    }

    function test_BorrowerIndexTracksLifecycle() public {
        BorrowerContext memory ctx = _mintPositions();
        facet.seedPoolWithMembership(1, address(borrowToken), ctx.lenderKey, 100 ether, true);
        facet.seedPoolWithMembership(2, address(collToken), ctx.borrowerKey, 50 ether, true);

        DirectTypes.DirectOfferParams memory offer = _offerParams(ctx.lenderPos, 1 days);
        uint256 agreementId = _postAndAccept(ctx.borrowerPos, offer);

        // Borrower index should list the agreement
        uint256[] memory agreements = facet.getBorrowerAgreements(ctx.borrowerPos, 0, 10);
        assertEq(agreements.length, 1, "one agreement tracked");
        assertEq(agreements[0], agreementId, "agreement id stored");

        // Repay clears index
        borrowToken.mint(borrower, 20 ether);
        vm.prank(borrower);
        borrowToken.approve(address(facet), type(uint256).max);
        vm.prank(borrower);
        facet.repay(agreementId);

        agreements = facet.getBorrowerAgreements(ctx.borrowerPos, 0, 10);
        assertEq(agreements.length, 0, "agreement removed after repay");
    }

    function test_Pagination() public {
        BorrowerContext memory ctx = _mintPositions();
        facet.seedPoolWithMembership(1, address(borrowToken), ctx.lenderKey, 500 ether, true);
        facet.seedPoolWithMembership(2, address(collToken), ctx.borrowerKey, 500 ether, true);

        borrowToken.mint(borrower, 100 ether);
        vm.startPrank(borrower);
        borrowToken.approve(address(facet), type(uint256).max);
        vm.stopPrank();

        // Post/accept 3 offers to create 3 agreements
        for (uint256 i = 0; i < 3; i++) {
            uint64 duration = uint64(1 days + i);
            DirectTypes.DirectOfferParams memory offer = _offerParams(ctx.lenderPos, duration);
            _postAndAccept(ctx.borrowerPos, offer);
        }

        uint256[] memory page1 = facet.getBorrowerAgreements(ctx.borrowerPos, 0, 2);
        uint256[] memory page2 = facet.getBorrowerAgreements(ctx.borrowerPos, 2, 2);
        assertEq(page1.length, 2, "page1 size");
        assertEq(page2.length, 1, "page2 size");
    }

    function _offerParams(uint256 lenderPos, uint64 durationSeconds)
        internal
        view
        returns (DirectTypes.DirectOfferParams memory offer)
    {
        offer.lenderPositionId = lenderPos;
        offer.lenderPoolId = 1;
        offer.collateralPoolId = 2;
        offer.collateralAsset = address(collToken);
        offer.borrowAsset = address(borrowToken);
        offer.principal = 10 ether;
        offer.aprBps = 0;
        offer.durationSeconds = durationSeconds;
        offer.collateralLockAmount = 5 ether;
        offer.allowEarlyRepay = false;
        offer.allowEarlyExercise = false;
        offer.allowLenderCall = false;
    }

    function _postAndAccept(uint256 borrowerPos, DirectTypes.DirectOfferParams memory offer)
        internal
        returns (uint256 agreementId)
    {
        vm.prank(lender);
        uint256 offerId = facet.postOffer(offer);
        vm.prank(borrower);
        agreementId = facet.acceptOffer(offerId, borrowerPos);
    }
}

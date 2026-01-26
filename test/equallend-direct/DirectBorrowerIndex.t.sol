// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

contract DirectBorrowerIndexTest is DirectDiamondTestBase {
    MockERC20 internal borrowToken;
    MockERC20 internal collToken;
    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        borrowToken = new MockERC20("B", "B", 18, 1_000_000 ether);
        collToken = new MockERC20("C", "C", 18, 1_000_000 ether);
        harness.setOwner(address(this));

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function _mintPositions() internal returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) {
        lenderPos = nft.mint(lender, 1);
        borrowerPos = nft.mint(borrower, 2);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);
    }

    function test_BorrowerIndexTracksLifecycle() public {
        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) = _mintPositions();
        harness.seedPoolWithMembership(1, address(borrowToken), lenderKey, 100 ether, true);
        harness.seedPoolWithMembership(2, address(collToken), borrowerKey, 50 ether, true);

        DirectTypes.DirectOfferParams memory offer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(collToken),
            borrowAsset: address(borrowToken),
            principal: 10 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lender);
        uint256 offerId = offers.postOffer(offer);
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        // Borrower index should list the agreement
        uint256[] memory agreements = views.getBorrowerAgreements(borrowerPos, 0, 10);
        assertEq(agreements.length, 1, "one agreement tracked");
        assertEq(agreements[0], agreementId, "agreement id stored");

        // Repay clears index
        borrowToken.mint(borrower, 20 ether);
        vm.prank(borrower);
        borrowToken.approve(address(diamond), type(uint256).max);
        vm.prank(borrower);
        lifecycle.repay(agreementId);

        agreements = views.getBorrowerAgreements(borrowerPos, 0, 10);
        assertEq(agreements.length, 0, "agreement removed after repay");
    }

    function test_Pagination() public {
        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) = _mintPositions();
        harness.seedPoolWithMembership(1, address(borrowToken), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(collToken), borrowerKey, 500 ether, true);

        borrowToken.mint(borrower, 100 ether);
        vm.startPrank(borrower);
        borrowToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        // Post/accept 3 offers to create 3 agreements
        for (uint256 i = 0; i < 3; i++) {
            DirectTypes.DirectOfferParams memory offer = DirectTypes.DirectOfferParams({
                lenderPositionId: lenderPos,
                lenderPoolId: 1,
                collateralPoolId: 2,
                collateralAsset: address(collToken),
                borrowAsset: address(borrowToken),
                principal: 10 ether,
                aprBps: 0,
                durationSeconds: uint64(1 days + i),
                collateralLockAmount: 5 ether,
                allowEarlyRepay: false,
                allowEarlyExercise: false,
                allowLenderCall: false});
            vm.prank(lender);
            uint256 offerId = offers.postOffer(offer);
            vm.prank(borrower);
            agreements.acceptOffer(offerId, borrowerPos);
        }

        uint256[] memory page1 = views.getBorrowerAgreements(borrowerPos, 0, 2);
        uint256[] memory page2 = views.getBorrowerAgreements(borrowerPos, 2, 2);
        assertEq(page1.length, 2, "page1 size");
        assertEq(page2.length, 1, "page2 size");
    }
}

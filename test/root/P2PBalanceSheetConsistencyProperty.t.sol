// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";

contract P2PBalanceSheetConsistencyPropertyTest is DirectDiamondTestBase {
    /// Feature: principal-accounting-normalization, Property 11: Balance Sheet Consistency
    function test_balanceSheetConsistency_acceptAndRepay() public {
        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        setUpDiamond();
        uint256 lenderTokenId = nft.mint(address(0xBEEF), 1);
        uint256 borrowerTokenId = nft.mint(address(0xCAFE), 2);
        finalizePositionNFT();

        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);

        harness.seedPoolWithMembership(1, address(token), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(token), borrowerKey, 200 ether, true);
        token.mint(address(0xBEEF), 400 ether);
        token.mint(address(0xCAFE), 100 ether);
        vm.prank(address(0xBEEF));
        token.approve(address(diamond), type(uint256).max);
        vm.prank(address(0xCAFE));
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(address(0xBEEF));
        uint256 offerId = offers.postOffer(params);

        (, uint256 lentBefore,) = views.directBalances(lenderKey, 1);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(1, lenderKey);
        vm.prank(address(0xCAFE));
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        (, uint256 lentAfter,) = views.directBalances(lenderKey, 1);
        uint256 lenderPrincipalAfter = views.getUserPrincipal(1, lenderKey);
        (, , uint256 borrowerBorrowedAfter) = views.directBalances(borrowerKey, 1);

        assertEq(lenderPrincipalBefore - lenderPrincipalAfter, params.principal, "lender principal delta");
        assertEq(lentAfter - lentBefore, params.principal, "lender lent delta");
        assertEq(borrowerBorrowedAfter, params.principal, "borrower debt delta");

        vm.prank(address(0xCAFE));
        lifecycle.repay(agreementId);

        (, uint256 lentAfterRepay,) = views.directBalances(lenderKey, 1);
        (, , uint256 borrowerBorrowedAfterRepay) = views.directBalances(borrowerKey, 1);
        assertEq(lentAfterRepay, lentBefore, "lent cleared on repay");
        assertEq(borrowerBorrowedAfterRepay, 0, "borrowed cleared on repay");
    }
}

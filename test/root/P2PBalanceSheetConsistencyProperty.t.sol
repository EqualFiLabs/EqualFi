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
        // Must approve the Diamond as an operator for the borrower's Position NFT 
        // to allow internal facets (like Agreements) to operate on it if required by checks,
        // although acceptOffer generally relies on msg.sender ownership. 
        // However, the error NotNFTOwner implies some internal check or context mismatch.
        // Let's verify the minting and owner setup. 
        // The error `NotNFTOwner` suggests the caller of `repay` is not the owner of the borrower NFT?
        // Ah, `repay` is called by `0xCAFE`, who owns token 2.
        // The error implies `repay` might be checking ownership incorrectly or against a different token.
        // Let's review the `repay` call context.
        
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        (, uint256 lentAfter,) = views.directBalances(lenderKey, 1);
        uint256 lenderPrincipalAfter = views.getUserPrincipal(1, lenderKey);
        (, , uint256 borrowerBorrowedAfter) = views.directBalances(borrowerKey, 1);

        assertEq(lenderPrincipalBefore - lenderPrincipalAfter, params.principal, "lender principal delta");
        assertEq(lentAfter - lentBefore, params.principal, "lender lent delta");
        assertEq(borrowerBorrowedAfter, params.principal, "borrower debt delta");

        vm.startPrank(address(0xCAFE));
        // Ensure approval for the token transfer during repayment
        token.approve(address(diamond), type(uint256).max); 
        lifecycle.repay(agreementId, _maxPayment(agreementId));
        vm.stopPrank();

        (, uint256 lentAfterRepay,) = views.directBalances(lenderKey, 1);
        (, , uint256 borrowerBorrowedAfterRepay) = views.directBalances(borrowerKey, 1);
        assertEq(lentAfterRepay, lentBefore, "lent cleared on repay");
        assertEq(borrowerBorrowedAfterRepay, 0, "borrowed cleared on repay");
    }
}

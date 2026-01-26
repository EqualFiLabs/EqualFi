// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";

contract DirectPrincipalConservationPropertyTest is DirectDiamondTestBase {
    /// Feature: principal-accounting-normalization, Property 3: P2P Principal Conservation
    function testFuzz_encumbrancePrincipalConservation(
        uint256 lenderPrincipal,
        uint256 borrowerPrincipal,
        uint256 offerPrincipal,
        uint256 collateralLockAmount
    ) public {
        lenderPrincipal = bound(lenderPrincipal, 1 ether, 1_000_000 ether);
        borrowerPrincipal = bound(borrowerPrincipal, 1 ether, 1_000_000 ether);
        offerPrincipal = bound(offerPrincipal, 1, lenderPrincipal);
        collateralLockAmount = bound(collateralLockAmount, 1, borrowerPrincipal);

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        setUpDiamond();
        uint256 lenderTokenId = nft.mint(address(0xBEEF), 1);
        uint256 borrowerTokenId = nft.mint(address(0xCAFE), 2);
        finalizePositionNFT();

        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);

        harness.seedPoolWithLtv(1, address(token), lenderKey, lenderPrincipal, 10_000, true);
        harness.seedPoolWithLtv(2, address(token), borrowerKey, borrowerPrincipal, 10_000, true);
        harness.setPoolTotals(1, lenderPrincipal, lenderPrincipal + offerPrincipal);
        token.mint(address(0xBEEF), offerPrincipal);
        token.mint(address(0xCAFE), collateralLockAmount);
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
            principal: offerPrincipal,
            aprBps: 0,
            durationSeconds: 1,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(address(0xBEEF));
        uint256 offerId = offers.postOffer(params);

        vm.prank(address(0xCAFE));
        agreements.acceptOffer(offerId, borrowerTokenId);

        uint256 lenderAfter = views.getUserPrincipal(1, lenderKey);
        uint256 borrowerDebt = views.directBorrowed(borrowerKey, 1);
        assertEq(lenderAfter, lenderPrincipal - offerPrincipal, "lender principal reduction mismatch");
        assertEq(borrowerDebt, offerPrincipal, "borrower debt mismatch");
    }
}

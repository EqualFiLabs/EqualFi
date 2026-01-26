// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectError_InvalidRatio, DirectError_InvalidFillAmount} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

contract DirectRatioTrancheOfferPropertyTest is DirectDiamondTestBase {
    MockERC20 internal borrowToken;
    MockERC20 internal collateralToken;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();
        borrowToken = new MockERC20("Borrow", "BRW", 18, 10_000_000 ether);
        collateralToken = new MockERC20("Collateral", "COL", 18, 10_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(address(0xFEE1), DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _ratioParams(uint256 lenderPos, uint256 cap, uint256 minFill)
        internal
        pure
        returns (DirectTypes.DirectRatioTrancheParams memory)
    {
        return DirectTypes.DirectRatioTrancheParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(0),
            borrowAsset: address(0),
            principalCap: cap,
            priceNumerator: 2 ether,
            priceDenominator: 1 ether,
            minPrincipalPerFill: minFill,
            aprBps: 1000,
            durationSeconds: 7 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });
    }

    function test_postRatioTrancheInvalidPrice() public {
        address lender = address(0xA11CE);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        finalizePositionNFT();
        DirectTypes.DirectRatioTrancheParams memory params = _ratioParams(lenderPos, 100 ether, 10 ether);
        params.borrowAsset = address(borrowToken);
        params.collateralAsset = address(collateralToken);
        params.priceNumerator = 0;

        vm.prank(lender);
        vm.expectRevert(DirectError_InvalidRatio.selector);
        offers.postRatioTrancheOffer(params);
    }

    function test_acceptRatioTranche_partialFillUpdatesRemainingAndLocksCollateral() public {
        address lender = address(0xA11CE);
        address borrower = address(0xB0B0B0);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrower, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(borrowToken), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(collateralToken), borrowerKey, 1_000 ether, true);
        borrowToken.mint(lender, 1_000 ether);
        collateralToken.mint(borrower, 1_000 ether);
        vm.prank(lender);
        borrowToken.approve(address(diamond), type(uint256).max);
        vm.prank(borrower);
        collateralToken.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectRatioTrancheParams memory params = _ratioParams(lenderPos, 600 ether, 100 ether);
        params.borrowAsset = address(borrowToken);
        params.collateralAsset = address(collateralToken);

        vm.prank(lender);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        vm.prank(borrower);
        agreements.acceptRatioTrancheOffer(offerId, borrowerPos, 200 ether);

        DirectTypes.DirectRatioTrancheOffer memory stored = views.getRatioTrancheOffer(offerId);
        assertEq(stored.principalRemaining, 400 ether, "remaining principal tracks fill");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 400 ether, "escrow reduced after partial fill");

        (uint256 lockedCollateral,) = views.getPositionDirectState(borrowerPos, COLLATERAL_POOL);
        // priceNumerator / priceDenominator = 2:1, so 200 principal => 400 collateral
        assertEq(lockedCollateral, 400 ether, "collateral locked via ratio");
    }

    function test_cancelRatioTrancheReleasesEscrow() public {
        address lender = address(0xC0FFEE);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(borrowToken), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(collateralToken), lenderKey, 500 ether, true);
        borrowToken.mint(lender, 500 ether);
        vm.prank(lender);
        borrowToken.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectRatioTrancheParams memory params = _ratioParams(lenderPos, 300 ether, 50 ether);
        params.borrowAsset = address(borrowToken);
        params.collateralAsset = address(collateralToken);

        vm.prank(lender);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        vm.prank(lender);
        offers.cancelRatioTrancheOffer(offerId);

        DirectTypes.DirectRatioTrancheOffer memory stored = views.getRatioTrancheOffer(offerId);
        assertTrue(stored.cancelled, "cancel flag");
        assertTrue(stored.filled, "filled after cancel");
        assertEq(stored.principalRemaining, 0, "principal remaining zero after cancel");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 0, "escrow released");
    }

    function test_acceptRatioTranche_revertsBelowMinFill() public {
        address lender = address(0xDEAD);
        address borrower = address(0xBEEF);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrower, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(borrowToken), lenderKey, 200 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(collateralToken), borrowerKey, 500 ether, true);
        borrowToken.mint(lender, 200 ether);
        collateralToken.mint(borrower, 500 ether);
        vm.prank(lender);
        borrowToken.approve(address(diamond), type(uint256).max);
        vm.prank(borrower);
        collateralToken.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectRatioTrancheParams memory params = _ratioParams(lenderPos, 150 ether, 50 ether);
        params.borrowAsset = address(borrowToken);
        params.collateralAsset = address(collateralToken);

        vm.prank(lender);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        vm.prank(borrower);
        vm.expectRevert(DirectError_InvalidFillAmount.selector);
        agreements.acceptRatioTrancheOffer(offerId, borrowerPos, 10 ether);
    }
}

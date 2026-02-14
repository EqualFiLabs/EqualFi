// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

contract DirectOfferIdKindPropertyTest is DirectDiamondTestBase {
    struct OfferSummary {
        uint256 offerId;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint16 aprBps;
        uint64 durationSeconds;
        uint256 collateralLockAmount;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
        bool isBorrowerOffer;
    }

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 5_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 5_000_000 ether);
    }

    function test_GlobalOfferIdsAreUniqueAndSummariesAreTypeAware() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        finalizePositionNFT();

        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, 1_000 ether, true);

        DirectTypes.DirectOfferParams memory lenderParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 900,
            durationSeconds: 7 days,
            collateralLockAmount: 120 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 lenderOfferId = offers.postOffer(lenderParams);

        DirectTypes.DirectBorrowerOfferParams memory borrowerParams = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 90 ether,
            aprBps: 700,
            durationSeconds: 5 days,
            collateralLockAmount: 100 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 borrowerOfferId = offers.postBorrowerOffer(borrowerParams);

        DirectTypes.DirectRatioTrancheParams memory ratioLenderParams = DirectTypes.DirectRatioTrancheParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principalCap: 200 ether,
            priceNumerator: 2 ether,
            priceDenominator: 1 ether,
            minPrincipalPerFill: 20 ether,
            aprBps: 800,
            durationSeconds: 6 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 ratioLenderOfferId = offers.postRatioTrancheOffer(ratioLenderParams);

        DirectTypes.DirectBorrowerRatioTrancheParams memory ratioBorrowerParams =
            DirectTypes.DirectBorrowerRatioTrancheParams({
                borrowerPositionId: borrowerPos,
                lenderPoolId: LENDER_POOL,
                collateralPoolId: COLLATERAL_POOL,
                collateralAsset: address(tokenB),
                borrowAsset: address(tokenA),
                collateralCap: 150 ether,
                priceNumerator: 1 ether,
                priceDenominator: 1 ether,
                minCollateralPerFill: 10 ether,
                aprBps: 600,
                durationSeconds: 4 days,
                allowEarlyRepay: false,
                allowEarlyExercise: false,
                allowLenderCall: false
            });

        vm.prank(borrowerOwner);
        uint256 ratioBorrowerOfferId = offers.postBorrowerRatioTrancheOffer(ratioBorrowerParams);

        assertEq(lenderOfferId + 1, borrowerOfferId, "borrower offer uses global offer sequence");
        assertEq(borrowerOfferId + 1, ratioLenderOfferId, "ratio lender offer uses global offer sequence");
        assertEq(ratioLenderOfferId + 1, ratioBorrowerOfferId, "ratio borrower offer uses global offer sequence");

        assertEq(uint8(views.getOfferKind(lenderOfferId)), uint8(DirectTypes.OfferKind.Lender), "kind lender");
        assertEq(uint8(views.getOfferKind(borrowerOfferId)), uint8(DirectTypes.OfferKind.Borrower), "kind borrower");
        assertEq(
            uint8(views.getOfferKind(ratioLenderOfferId)),
            uint8(DirectTypes.OfferKind.RatioLender),
            "kind ratio lender"
        );
        assertEq(
            uint8(views.getOfferKind(ratioBorrowerOfferId)),
            uint8(DirectTypes.OfferKind.RatioBorrower),
            "kind ratio borrower"
        );

        OfferSummary memory lenderSummary = _offerSummary(lenderOfferId);
        assertEq(lenderSummary.lender, lenderOwner, "lender summary owner");
        assertFalse(lenderSummary.isBorrowerOffer, "lender summary type");
        assertEq(lenderSummary.principal, lenderParams.principal, "lender summary principal");

        OfferSummary memory borrowerSummary = _offerSummary(borrowerOfferId);
        assertEq(borrowerSummary.borrower, borrowerOwner, "borrower summary owner");
        assertTrue(borrowerSummary.isBorrowerOffer, "borrower summary type");
        assertEq(borrowerSummary.principal, borrowerParams.principal, "borrower summary principal");

        OfferSummary memory ratioLenderSummary = _offerSummary(ratioLenderOfferId);
        assertEq(ratioLenderSummary.lender, lenderOwner, "ratio lender summary owner");
        assertFalse(ratioLenderSummary.isBorrowerOffer, "ratio lender summary type");
        assertEq(ratioLenderSummary.principal, ratioLenderParams.principalCap, "ratio lender summary principal");

        OfferSummary memory ratioBorrowerSummary = _offerSummary(ratioBorrowerOfferId);
        assertEq(ratioBorrowerSummary.borrower, borrowerOwner, "ratio borrower summary owner");
        assertTrue(ratioBorrowerSummary.isBorrowerOffer, "ratio borrower summary type");
        assertEq(
            ratioBorrowerSummary.principal,
            ratioBorrowerParams.collateralCap,
            "ratio borrower summary collateral remaining"
        );
    }

    function _offerSummary(uint256 offerId) internal view returns (OfferSummary memory summary) {
        (bool ok, bytes memory data) = address(diamond).staticcall(abi.encodeWithSignature("getOfferSummary(uint256)", offerId));
        require(ok, "getOfferSummary failed");
        summary = abi.decode(data, (OfferSummary));
    }
}

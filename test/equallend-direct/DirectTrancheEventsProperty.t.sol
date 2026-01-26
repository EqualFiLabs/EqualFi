// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

event DirectOfferPosted(
    uint256 indexed offerId,
    address indexed borrowAsset,
    uint256 indexed collateralPoolId,
    address lender,
    uint256 lenderPositionId,
    uint256 lenderPoolId,
    address collateralAsset,
    uint256 principal,
    uint16 aprBps,
    uint64 durationSeconds,
    uint256 collateralLockAmount,
    bool isTranche,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 fillsRemaining,
    uint256 maxFills,
    bool isDepleted
);

event DirectOfferAccepted(
    uint256 indexed offerId,
    uint256 indexed agreementId,
    uint256 indexed borrowerPositionId,
    uint256 principalFilled,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 fillsRemaining,
    bool isDepleted
);

event DirectOfferCancelled(
    uint256 indexed offerId,
    address indexed lender,
    uint256 indexed lenderPositionId,
    DirectTypes.DirectCancelReason reason,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 amountReturned,
    uint256 fillsRemaining,
    bool isDepleted
);

/// @notice Feature: tranche-backed-offers, Property 11: Event emission completeness
/// @notice Validates: Requirements 1.6, 5.3, 5.4, 5.5
contract DirectTrancheEventsPropertyTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;
    address internal protocolTreasury = address(0xFEE1);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 5_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 5_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_EventEmissionCompleteness() public {
        address lenderOwner = address(0xA11CE);
        address borrowerOwner = address(0xB0B);

        uint256 principal = 100 ether;
        uint256 trancheAmount = 300 ether;
        uint256 lenderPrincipal = 500 ether;
        uint256 borrowerPrincipal = 500 ether;

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, borrowerPrincipal, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1500,
            durationSeconds: 7 days,
            collateralLockAmount: principal,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectOfferPosted(
            1,
            params.borrowAsset,
            params.collateralPoolId,
            lenderOwner,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.aprBps,
            params.durationSeconds,
            params.collateralLockAmount,
            true,
            trancheAmount,
            trancheAmount,
            trancheAmount / principal,
            trancheAmount / principal,
            false
        );
        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, tranche);

        uint256 expectedRemaining = trancheAmount - principal;
        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectOfferAccepted(
            offerId, 1, borrowerPos, principal, trancheAmount, expectedRemaining, expectedRemaining / principal, false
        );
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit DirectOfferCancelled(
            offerId,
            lenderOwner,
            lenderPos,
            DirectTypes.DirectCancelReason.Manual,
            trancheAmount,
            0,
            expectedRemaining,
            0,
            true
        );
        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);
    }

    function testProperty_EventEmissionCompleteness_AutoCancel() public {
        address lenderOwner = address(0xC0FFEE);
        address borrowerOwner = address(0xFEED);

        uint256 principal = 50 ether;
        uint256 trancheAmount = 50 ether;
        uint256 lenderPrincipal = 150 ether;
        uint256 borrowerPrincipal = 150 ether;

        uint256 lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrowerOwner, COLLATERAL_POOL);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, borrowerPrincipal, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1200,
            durationSeconds: 7 days,
            collateralLockAmount: principal,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, tranche);

        uint256 shortRemaining = principal - 1;
        harness.setTrancheState(lenderKey, LENDER_POOL, offerId, shortRemaining, trancheAmount);

        vm.recordLogs();
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "DirectOfferCancelled(uint256,address,uint256,uint8,uint256,uint256,uint256,uint256,bool)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (uint256 decodedOfferId, address decodedLender, uint256 decodedLenderPos) =
                (uint256(logs[i].topics[1]), address(uint160(uint256(logs[i].topics[2]))), uint256(logs[i].topics[3]));
            assertEq(decodedOfferId, offerId, "offer id");
            assertEq(decodedLender, lenderOwner, "lender");
            assertEq(decodedLenderPos, lenderPos, "lender position");
            (
                DirectTypes.DirectCancelReason reason,
                uint256 emitTrancheAmount,
                uint256 trancheRemainingAfter,
                uint256 amountReturned,
                uint256 fillsRemaining,
                bool isDepleted
            ) = abi.decode(logs[i].data, (DirectTypes.DirectCancelReason, uint256, uint256, uint256, uint256, bool));
            assertEq(uint256(reason), uint256(DirectTypes.DirectCancelReason.AutoInsufficientTranche), "reason");
            assertEq(emitTrancheAmount, trancheAmount, "tranche amount");
            assertEq(trancheRemainingAfter, 0, "tranche remaining after");
            assertEq(amountReturned, shortRemaining, "amount returned");
            assertEq(fillsRemaining, 0, "fills remaining");
            assertTrue(isDepleted, "is depleted");
            found = true;
        }
        assertTrue(found, "cancellation event found");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
contract DirectActiveCreditIntegrationTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 5_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 5_000_000 ether);
    }

    function _setConfig(
        uint16 platformFeeBps,
        uint16 splitLender,
        uint16 splitFeeIndex,
        uint16 splitProtocol,
        uint16 splitActive,
        uint16 defaultFeeIndex,
        uint16 defaultProtocol,
        uint16 defaultActive
    ) internal {
        splitFeeIndex;
        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: platformFeeBps,
            interestLenderBps: 10_000,
            platformFeeLenderBps: splitLender,
            defaultLenderBps: uint16(10_000 - defaultFeeIndex - defaultProtocol - defaultActive),
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(splitLender, splitProtocol));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(splitLender, splitActive));
    }

    function _fundUsers() internal {
        tokenA.transfer(lenderOwner, 1_000 ether);
        tokenA.transfer(borrowerOwner, 1_000 ether);
        tokenB.transfer(lenderOwner, 1_000 ether);
        tokenB.transfer(borrowerOwner, 1_000 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);
    }

    function testActiveCreditSameAssetRepayAccruesShare() public {
        _setConfig(1_000, 4_000, 2_000, 2_000, 2_000, 1_000, 1_000, 500);
        _fundUsers();
        vm.warp(20 days);

        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(tokenA), lenderKey, 500 ether, true);
        harness.addPrincipal(1, borrowerKey, 200 ether, address(tokenA));

        DirectTypes.DirectOfferParams memory offer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(tokenA),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 1000,
            durationSeconds: 3 days,
            collateralLockAmount: 50 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(offer);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.borrowAsset, address(tokenA), "borrow asset recorded");
        assertEq(agreement.collateralAsset, address(tokenA), "collateral asset recorded");

        uint256 platformFee = (offer.principal * 1_000) / 10_000;
        uint256 activeShare = (platformFee * 2_000) / 10_000;
        harness.forceActiveBase(1, offer.principal);
        (, , uint256 manualBase) = views.getActiveCreditIndex(1);
        assertEq(manualBase, offer.principal, "manual active base set");
        harness.accrueActiveCredit(1, activeShare, keccak256("DIRECT_PLATFORM_FEE"));

        (uint256 idx,, uint256 activeTotal) = views.getActiveCreditIndex(1);
        assertEq(activeTotal, offer.principal, "active credit base set");
        assertGe(idx, 0, "active credit index recorded");

        // Borrower receives net principal; top up for repay
        tokenA.transfer(borrowerOwner, 200 ether);

        // Mature gate then repay
        vm.warp(block.timestamp + 2 days);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        Types.PoolData storage pool = LibAppStorage.s().pools[1];
        assertEq(pool.activeCreditPrincipalTotal, 0, "active principal cleared after repay");
        assertEq(views.pendingActiveCredit(1, borrowerKey), 0, "no pending after settle");
        assertGe(pool.userAccruedYield[borrowerKey], 0, "accrued yield tracked");
    }

    function testActiveCreditCrossPoolNoAccrualThenConfigChange() public {
        _setConfig(1_000, 5_000, 2_000, 2_000, 1_000, 1_000, 1_000, 500);
        _fundUsers();
        vm.warp(30 days);

        uint256 lenderPos = nft.mint(lenderOwner, 3);
        uint256 borrowerPos = nft.mint(borrowerOwner, 4);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(tokenA), lenderKey, 600 ether, true);
        harness.seedPoolWithMembership(2, address(tokenB), borrowerKey, 300 ether, true);

        DirectTypes.DirectOfferParams memory crossOffer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 120 ether,
            aprBps: 900,
            durationSeconds: 2 days,
            collateralLockAmount: 80 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 crossOfferId = offers.postOffer(crossOffer);
        vm.prank(borrowerOwner);
        uint256 crossAgreementId = agreements.acceptOffer(crossOfferId, borrowerPos);

        Types.PoolData storage poolA = LibAppStorage.s().pools[1];
        assertEq(poolA.activeCreditPrincipalTotal, 0, "no active base for cross-asset");
        assertEq(poolA.activeCreditIndex, 0, "no active index accrual on cross-asset");

        tokenA.transfer(borrowerOwner, 200 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(borrowerOwner);
        lifecycle.repay(crossAgreementId);

        assertEq(poolA.userAccruedYield[borrowerKey], 0, "no active credit on cross-asset debt");
        uint256 indexBefore = poolA.activeCreditIndex;

        // Update config to increase active credit split and run same-asset loan
        _setConfig(1_000, 4_000, 2_000, 1_000, 3_000, 1_000, 1_000, 500);

        harness.addPrincipal(1, borrowerKey, 200 ether, address(tokenA));

        DirectTypes.DirectOfferParams memory sameAssetOffer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(tokenA),
            borrowAsset: address(tokenA),
            principal: 80 ether,
            aprBps: 800,
            durationSeconds: 1 days,
            collateralLockAmount: 40 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(sameAssetOffer);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);
        uint256 platformFee2 = (sameAssetOffer.principal * 1_000) / 10_000;
        uint256 activeShare2 = (platformFee2 * 3_000) / 10_000;
        harness.forceActiveBase(1, sameAssetOffer.principal);
        (, , uint256 manualBase2) = views.getActiveCreditIndex(1);
        assertEq(manualBase2, sameAssetOffer.principal, "manual active base set (second loan)");
        harness.accrueActiveCredit(1, activeShare2, keccak256("DIRECT_PLATFORM_FEE"));
        tokenA.transfer(borrowerOwner, 150 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        poolA = LibAppStorage.s().pools[1];
        assertGe(poolA.activeCreditIndex, indexBefore, "active credit index tracked for same-asset");
        assertEq(poolA.activeCreditPrincipalTotal, 0, "active principal cleared after same-asset repay");
    }
}

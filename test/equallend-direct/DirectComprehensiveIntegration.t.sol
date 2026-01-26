// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

contract DirectComprehensiveIntegrationTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal operator = address(0x0B0);
    address internal protocolTreasury = address(0xF00D);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 7000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(7000, 1000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(7000, 0));
    }

    function testIntegration_SettlementPathsAndFees() public {
        vm.warp(50 days);
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        uint256 lenderPos2 = nft.mint(lenderOwner, 3);
        uint256 borrowerPos2 = nft.mint(borrowerOwner, 4);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        bytes32 lenderKey2 = nft.getPositionKey(lenderPos2);
        bytes32 borrowerKey2 = nft.getPositionKey(borrowerPos2);

        // Same-asset pools for exercise path
        harness.addPoolMember(1, address(tokenA), lenderKey, 500 ether, true);
        harness.addPoolMember(1, address(tokenA), borrowerKey, 30 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory exerciseParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(tokenA),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 exerciseOfferId = offers.postOffer(exerciseParams);
        vm.prank(borrowerOwner);
        uint256 exerciseAgreementId = agreements.acceptOffer(exerciseOfferId, borrowerPos);

        uint256 borrowerBalanceBefore = tokenA.balanceOf(borrowerOwner);
        uint256 borrowerPrincipalBefore = LibAppStorage.s().pools[1].userPrincipal[borrowerKey];
        uint256 lenderPrincipalBefore = LibAppStorage.s().pools[1].userPrincipal[lenderKey];
        uint256 protocolPrincipalBefore = LibAppStorage.s().pools[1].userPrincipal[LibPositionHelpers.systemPositionKey(protocolTreasury)];
        uint256 feeIndexBefore = LibAppStorage.s().pools[1].feeIndex;
        uint256 totalDepositsBefore = LibAppStorage.s().pools[1].totalDeposits;

        vm.warp(block.timestamp + 1 days);
        vm.prank(borrowerOwner);
        lifecycle.exerciseDirect(exerciseAgreementId);

        DirectTypes.DirectAgreement memory exercised = views.getAgreement(exerciseAgreementId);
        assertEq(uint8(exercised.status), uint8(DirectTypes.DirectStatus.Exercised), "status exercised");
        assertEq(tokenA.balanceOf(borrowerOwner), borrowerBalanceBefore, "premium unchanged on exercise");

        uint256 collateralAvailable = borrowerPrincipalBefore >= exerciseParams.collateralLockAmount
            ? exerciseParams.collateralLockAmount
            : borrowerPrincipalBefore;
        uint256 protocolShare = (collateralAvailable * 1000) / 10_000;
        uint256 remainingAfterProtocol =
            collateralAvailable > protocolShare ? collateralAvailable - protocolShare : 0;
        uint256 feeIndexShare = (remainingAfterProtocol * 2000) / 10_000;
        uint256 lenderShare = collateralAvailable - feeIndexShare - protocolShare;

        assertEq(
            LibAppStorage.s().pools[1].userPrincipal[lenderKey],
            lenderPrincipalBefore + lenderShare,
            "lender share on exercise"
        );
        assertEq(
            LibAppStorage.s().pools[1].userPrincipal[LibPositionHelpers.systemPositionKey(protocolTreasury)],
            protocolPrincipalBefore + protocolShare,
            "protocol share on exercise"
        );

        uint256 feeIndexDenominator = totalDepositsBefore > feeIndexShare
            ? totalDepositsBefore - feeIndexShare
            : totalDepositsBefore;
        uint256 expectedIndexDelta = feeIndexDenominator == 0 ? 0 : (feeIndexShare * 1e18) / feeIndexDenominator;
        assertEq(LibAppStorage.s().pools[1].feeIndex, feeIndexBefore + expectedIndexDelta, "fee index on exercise");

        // Cross-asset recover path
        harness.addPoolMember(3, address(tokenA), lenderKey2, 500 ether, true);
        harness.addPoolMember(4, address(tokenB), borrowerKey2, 30 ether, true);

        tokenA.transfer(lenderOwner, 300 ether);
        tokenB.transfer(borrowerOwner, 50 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory recoverParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos2,
            lenderPoolId: 3,
            collateralPoolId: 4,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 recoverOfferId = offers.postOffer(recoverParams);
        vm.prank(borrowerOwner);
        uint256 recoverAgreementId = agreements.acceptOffer(recoverOfferId, borrowerPos2);
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(block.timestamp, recoverParams.durationSeconds);

        uint256 lenderPrincipalBeforeRecover = LibAppStorage.s().pools[3].userPrincipal[lenderKey2];
        uint256 protocolPrincipalBeforeRecover = LibAppStorage.s().pools[4].userPrincipal[LibPositionHelpers.systemPositionKey(protocolTreasury)];
        uint256 feeIndexBeforeRecover = LibAppStorage.s().pools[4].feeIndex;
        uint256 totalDepositsBeforeRecover = LibAppStorage.s().pools[4].totalDeposits;
        uint256 borrowerPrincipalBeforeRecover = LibAppStorage.s().pools[4].userPrincipal[borrowerKey2];

        vm.warp(dueTimestamp + 1 days);
        vm.prank(stranger);
        lifecycle.recover(recoverAgreementId);

        DirectTypes.DirectAgreement memory recovered = views.getAgreement(recoverAgreementId);
        assertEq(uint8(recovered.status), uint8(DirectTypes.DirectStatus.Defaulted), "status defaulted");

        uint256 collateralAvailableRecover = borrowerPrincipalBeforeRecover >= recoverParams.collateralLockAmount
            ? recoverParams.collateralLockAmount
            : borrowerPrincipalBeforeRecover;
        uint256 protocolShareRecover = (collateralAvailableRecover * 1000) / 10_000;
        uint256 feeIndexShareRecover = (collateralAvailableRecover * 2000) / 10_000;
        uint256 lenderShareRecover = collateralAvailableRecover - protocolShareRecover - feeIndexShareRecover;

        assertEq(LibAppStorage.s().pools[3].userPrincipal[lenderKey2], lenderPrincipalBeforeRecover, "lender principal unchanged");
        assertEq(
            LibAppStorage.s().pools[4].userPrincipal[lenderKey2],
            lenderShareRecover,
            "lender credited in collateral pool"
        );
        assertEq(
            LibAppStorage.s().pools[4].userPrincipal[LibPositionHelpers.systemPositionKey(protocolTreasury)],
            protocolPrincipalBeforeRecover + protocolShareRecover,
            "protocol credited in collateral pool"
        );

        uint256 expectedRecoverDelta = totalDepositsBeforeRecover == 0
            ? 0
            : (feeIndexShareRecover * 1e18) / totalDepositsBeforeRecover;
        assertEq(LibAppStorage.s().pools[4].feeIndex, feeIndexBeforeRecover + expectedRecoverDelta, "fee index on recover");
    }

    function testIntegration_PositionNftOperatorAccess() public {
        vm.warp(75 days);
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.addPoolMember(1, address(tokenA), lenderKey, 500 ether, true);
        harness.addPoolMember(2, address(tokenB), borrowerKey, 40 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        tokenB.transfer(borrowerOwner, 50 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, borrowerPos));
        lifecycle.repay(agreementId);

        vm.prank(borrowerOwner);
        nft.setApprovalForAll(operator, true);
        vm.prank(borrowerOwner);
        tokenA.transfer(operator, 100 ether);
        vm.prank(operator);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(operator);
        lifecycle.repay(agreementId);
    }
}

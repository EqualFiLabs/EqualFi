// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// **Feature: active-credit-index, Property 18: Default Fee Integration**
/// Validates: Requirements 10.3, 10.4, 10.5
contract DirectDefaultFeeIntegrationPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    uint16 internal treasurySplitBps;
    uint16 internal activeSplitBps;

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Token", "TKN", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 7500,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        treasurySplitBps = DirectTestUtils.treasurySplitFromLegacy(7500, 1000);
        activeSplitBps = DirectTestUtils.activeSplitFromLegacy(7500, 500);
        harness.setTreasuryShare(protocolTreasury, treasurySplitBps);
        harness.setActiveCreditShare(activeSplitBps);
    }

    function testProperty_DefaultFeeIntegration() public {
        vm.warp(30 days);
        uint256 lockAmount = 100 ether;
        uint256 borrowerPrincipal = 200 ether;

        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPool(1, address(asset), lenderKey, 500 ether);
        harness.seedPool(2, address(asset), borrowerKey, borrowerPrincipal);

        (uint256 borrowerPrincipalSeed, uint256 totalSeed, uint256 trackedSeed,, uint256 activeIndexSeed) =
            views.poolState(2, borrowerKey);
        assertEq(borrowerPrincipalSeed, borrowerPrincipal, "seeded borrower principal");
        assertEq(totalSeed, borrowerPrincipal, "seeded borrower deposits");
        assertEq(trackedSeed, borrowerPrincipal, "seeded borrower tracked");

        DirectTypes.DirectAgreement memory agreement = DirectTypes.DirectAgreement({
            agreementId: 1,
            lender: lenderOwner,
            borrower: borrowerOwner,
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            borrowerPositionId: borrowerPos,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: lockAmount,
            userInterest: 0,
            dueTimestamp: uint64(block.timestamp - 10 days),
            collateralLockAmount: lockAmount,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: false
        });
        harness.setAgreement(agreement);
        harness.setDirectState(
            borrowerKey, lenderKey, agreement.collateralPoolId, agreement.lenderPoolId, lockAmount, lockAmount, agreement.agreementId
        );
        harness.forceActiveBase(agreement.collateralPoolId, borrowerPrincipal - lockAmount);

        (, uint256 totalBefore, uint256 trackedBefore, uint256 feeIndexBefore, uint256 activeIndexBefore) =
            views.poolState(2, borrowerKey);

        lifecycle.recover(agreement.agreementId);

        uint256 lenderShare = (lockAmount * 7500) / 10_000;
        uint256 remainder = lockAmount - lenderShare;
        (uint256 expectedProtocol, uint256 expectedActiveCredit, uint256 expectedFeeIndex) =
            DirectTestUtils.previewSplit(remainder, treasurySplitBps, activeSplitBps, true);

        (uint256 borrowerPrincipalAfter, uint256 totalAfter, uint256 trackedAfter, uint256 feeIndexAfter, uint256 activeIndexAfter) =
            views.poolState(2, borrowerKey);
        (uint256 lenderPrincipalAfter, uint256 lenderTotalAfter, uint256 lenderTrackedAfter,,) =
            views.poolState(1, lenderKey);
        (uint256 protocolPrincipalAfter,, uint256 protocolTrackedAfter,,) =
            views.poolState(1, LibPositionHelpers.systemPositionKey(protocolTreasury));

        assertEq(borrowerPrincipalAfter, borrowerPrincipal - lockAmount, "borrower collateral applied");
        assertEq(totalAfter, borrowerPrincipal - lockAmount, "collateral removed from deposits");
        assertEq(
            trackedAfter,
            trackedBefore - (lenderShare + expectedProtocol) + expectedActiveCredit,
            "collateral pool tracked balance"
        );
        assertEq(
            feeIndexAfter,
            feeIndexBefore + (expectedFeeIndex * 1e18) / (borrowerPrincipal - lockAmount),
            "fee index accrued"
        );
        assertEq(
            activeIndexAfter,
            activeIndexBefore + (expectedActiveCredit * 1e18) / (borrowerPrincipal - lockAmount),
            "active credit index accrued"
        );
        assertGt(activeIndexAfter, activeIndexBefore, "active credit index advanced");

        assertEq(lenderPrincipalAfter, 500 ether + lenderShare, "lender principal increased");
        assertEq(protocolPrincipalAfter, expectedProtocol, "protocol principal recorded");
        assertEq(
            lenderTotalAfter,
            500 ether + lenderShare + expectedProtocol,
            "lender pool deposits updated"
        );
        assertEq(lenderTrackedAfter, lenderTotalAfter, "lender pool tracked balance");

        assertEq(views.sameAssetDebt(borrowerKey, address(asset)), 0, "same-asset debt cleared");
        assertEq(uint8(views.agreementStatus(agreement.agreementId)), uint8(DirectTypes.DirectStatus.Defaulted));
    }
}

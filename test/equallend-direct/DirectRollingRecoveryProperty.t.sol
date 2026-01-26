// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {RollingError_RecoveryNotEligible} from "../../src/libraries/Errors.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

/// @notice Feature: p2p-rolling-loans, Property 7: Recovery Timing and Distribution
/// @notice Validates: Requirements 5.1, 5.2, 5.3, 5.4
/// forge-config: default.fuzz.runs = 100
contract DirectRollingRecoveryPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xD00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, 0);
    }

    function _setupAgreement()
        internal
        returns (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey)
    {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPositionId);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(1, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 200 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 520,
            upfrontPremium: 0,
            allowAmortization: false,
            allowEarlyRepay: false,
            allowEarlyExercise: false});

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId);
        DirectTypes.DirectRollingAgreement memory ag = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(ag.principal, offerParams.principal, "principal stored");
        assertEq(ag.outstandingPrincipal, offerParams.principal, "agreement principal initialized");
    }

    function testProperty_RecoveryTimingAndDistribution() public {
        vm.warp(1_000_000);
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey) = _setupAgreement();

        harness.setArrears(agreementId, 20 ether);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);
        harness.forceNextDue(agreementId, uint64(block.timestamp - agreement.gracePeriodSeconds - 1));
        agreement = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(agreement.outstandingPrincipal, 100 ether, "principal tracked");
        assertEq(agreement.arrears, 20 ether, "arrears tracked");
        DirectTypes.DirectConfig memory cfg = views.getDirectConfig();
        assertEq(cfg.defaultLenderBps, 10_000, "default lender split full");
        vm.warp(block.timestamp + 30 days);

        uint256 borrowerPrincipalBefore = views.getUserPrincipal(1, borrowerKey);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(1, lenderKey);
        uint256 treasuryBefore = views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury));

        vm.prank(lenderOwner);
        rollingLifecycle.recoverRolling(agreementId);

        DirectTypes.DirectRollingAgreement memory afterRecovery = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(uint256(afterRecovery.status), uint256(DirectTypes.DirectStatus.Defaulted), "status defaulted");
        assertEq(afterRecovery.arrears, 0, "arrears cleared");
        assertEq(afterRecovery.outstandingPrincipal, 0, "principal cleared");
        assertEq(views.directLocked(borrowerKey, afterRecovery.collateralPoolId), 0, "collateral unlocked");

        // Collateral seized: 200; penalty: 12 (10% of 120); arrears+principal paid: 120; borrower refund: 68
        assertEq(
            views.getUserPrincipal(1, lenderKey) - lenderPrincipalBefore,
            120 ether,
            "lender receives arrears+principal share"
        );
        assertEq(
            views.getUserPrincipal(1, LibPositionHelpers.systemPositionKey(protocolTreasury)) - treasuryBefore,
            12 ether,
            "protocol receives penalty"
        );
        assertEq(
            views.getUserPrincipal(1, borrowerKey),
            borrowerPrincipalBefore - 200 ether + 68 ether,
            "borrower refunded remainder after penalty and debt coverage"
        );
    }

    function testProperty_RecoveryRespectsGracePeriod() public {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey) = _setupAgreement();
        harness.setArrears(agreementId, 5 ether);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);

        vm.expectRevert(RollingError_RecoveryNotEligible.selector);
        rollingLifecycle.recoverRolling(agreementId);

        // No state changes when recovery not eligible
        assertEq(uint256(agreement.status), uint256(DirectTypes.DirectStatus.Active), "remains active");
        assertEq(views.directLocked(borrowerKey, agreement.collateralPoolId), agreement.collateralLockAmount, "collateral still locked");
        assertEq(views.getUserPrincipal(1, lenderKey), 900 ether, "lender unchanged");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidAgreementState} from "../../src/libraries/Errors.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 5: Terminal state enforcement
/// @notice Validates: Requirements 4.1, 4.2, 4.3, 4.4
contract DirectTerminalStatePropertyTest is DirectDiamondTestBase {
    address internal borrower = address(0xB0B);
    address internal lender = address(0xA11CE);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        setUpDiamond();
    }

    function testProperty_TerminalStateEnforcement() public {
        DirectTypes.DirectAgreement memory base = DirectTypes.DirectAgreement({
            agreementId: 1,
            lender: lender,
            borrower: borrower,
            lenderPositionId: 1,
            lenderPoolId: 1,
            borrowerPositionId: 2,
            collateralPoolId: 2,
            collateralAsset: address(0x1),
            borrowAsset: address(0x2),
            principal: 1 ether,
            userInterest: 0,
            dueTimestamp: uint64(block.timestamp + 1 days),
            collateralLockAmount: 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            status: DirectTypes.DirectStatus.Repaid,
            interestRealizedUpfront: true
        });

        _assertTerminalStateReverts(base, DirectTypes.DirectStatus.Repaid);
        _assertTerminalStateReverts(base, DirectTypes.DirectStatus.Exercised);
        _assertTerminalStateReverts(base, DirectTypes.DirectStatus.Defaulted);
    }

    function _assertTerminalStateReverts(
        DirectTypes.DirectAgreement memory agreement,
        DirectTypes.DirectStatus terminalStatus
    ) internal {
        agreement.status = terminalStatus;
        harness.setAgreement(agreement);

        vm.prank(borrower);
        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        lifecycle.repay(agreement.agreementId);

        vm.prank(borrower);
        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        lifecycle.exerciseDirect(agreement.agreementId);

        vm.prank(stranger);
        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        lifecycle.recover(agreement.agreementId);
    }
}

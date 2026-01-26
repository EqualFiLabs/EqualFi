// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {DirectError_InvalidAgreementState} from "../../src/libraries/Errors.sol";
import {FeeBaseOverflow, InvalidAssetComparison, NegativeFeeBase, SameAssetDebtMismatch} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";

contract AccountingErrorHarness {
    function validateDebt(uint256 expected, uint256 actual) external pure {
        LibSolvencyChecks.validateSameAssetDebt(expected, actual);
    }

    function feeBaseCrossAsset(uint256 lockedCollateral, uint256 unlockedPrincipal) external pure returns (uint256) {
        return LibNetEquity.calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
    }

    function sameAssetComparison(address collateralAsset, address lentAsset) external pure returns (bool) {
        return LibNetEquity.isSameAssetP2P(collateralAsset, lentAsset);
    }

    function feeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) external pure returns (uint256) {
        return LibNetEquity.validateFeeBaseSameAsset(principal, sameAssetDebt);
    }
}

contract AccountingErrorHandlingTest is Test {
    function test_feeBaseOverflow_reverts() public {
        AccountingErrorHarness harness = new AccountingErrorHarness();
        vm.expectRevert(FeeBaseOverflow.selector);
        harness.feeBaseCrossAsset(type(uint256).max, 1);
    }

    function test_invalidAssetComparison_reverts() public {
        AccountingErrorHarness harness = new AccountingErrorHarness();
        vm.expectRevert(InvalidAssetComparison.selector);
        harness.sameAssetComparison(address(0), address(0xBEEF));
    }

    function test_negativeFeeBase_reverts() public {
        AccountingErrorHarness harness = new AccountingErrorHarness();
        vm.expectRevert(NegativeFeeBase.selector);
        harness.feeBaseSameAsset(1, 2);
    }

    function test_debtMismatch_reverts() public {
        AccountingErrorHarness harness = new AccountingErrorHarness();
        vm.expectRevert(abi.encodeWithSelector(SameAssetDebtMismatch.selector, 1, 2));
        harness.validateDebt(1, 2);
    }
}

contract AccountingErrorHandlingDirectTest is DirectDiamondTestBase {
    MockERC20 internal token;

    function setUp() public {
        setUpDiamond();
        token = new MockERC20("Mock", "MOCK", 18, 0);
    }

    function test_p2p_inconsistentDebt_reverts() public {
        address lender = address(0xBEEF);
        address borrower = address(0xCAFE);
        uint256 lenderId = nft.mint(lender, 1);
        uint256 borrowerId = nft.mint(borrower, 2);
        finalizePositionNFT();

        bytes32 lenderKey = nft.getPositionKey(lenderId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerId);
        harness.seedPoolWithMembership(1, address(token), lenderKey, 200 ether, true);
        harness.seedPoolWithMembership(2, address(token), borrowerKey, 100 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderId,
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

        token.mint(lender, 200 ether);
        token.mint(borrower, 100 ether);
        vm.prank(lender);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(borrower);
        token.approve(address(diamond), type(uint256).max);

        vm.prank(lender);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerId);

        harness.setDirectBorrowed(borrowerKey, 1, 0);

        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        vm.prank(borrower);
        lifecycle.repay(agreementId);
    }
}

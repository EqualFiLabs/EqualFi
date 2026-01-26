// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

/// @notice Feature: multi-pool-position-nfts, Property 4: Direct Agreement Solvency Preservation
/// @notice Validates: Requirements 5.1, 5.2, 5.3, 5.4
/// forge-config: default.fuzz.runs = 50
contract DirectInternalSettlementPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("A", "A", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function _mintPositions(uint256 lenderPrincipal, uint256 borrowerPrincipal)
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lender, 1);
        borrowerPos = nft.mint(borrower, 1);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);
        harness.addPoolMember(1, address(asset), lenderKey, lenderPrincipal, true);
        harness.addPoolMember(1, address(asset), borrowerKey, borrowerPrincipal, true);
    }

    function testProperty_DirectAgreementSolvencyPreserved() public {
        uint256 lenderPrincipal = 1_000 ether;
        uint256 borrowerPrincipal = 500 ether;
        uint256 principal = 200 ether;

        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) =
            _mintPositions(lenderPrincipal, borrowerPrincipal);
        (uint256 lenderPrincipalSeed,, , ,) = views.poolState(1, lenderKey);
        (uint256 borrowerPrincipalSeed,, , ,) = views.poolState(1, borrowerKey);
        assertEq(lenderPrincipalSeed, lenderPrincipal, "seed lender principal");
        assertEq(borrowerPrincipalSeed, borrowerPrincipal, "seed borrower principal");

        DirectTypes.DirectOfferParams memory offer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: principal,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: principal / 2,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lender);
        uint256 offerId = offers.postOffer(offer);
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        // Ledger-based settlement: lender liquidity debited, borrower principal unchanged
        (uint256 borrowerAfter,, uint256 trackedAfterAccept,,) = views.poolState(1, borrowerKey);
        assertEq(borrowerAfter, borrowerPrincipal, "borrower principal unchanged");
        assertEq(trackedAfterAccept, lenderPrincipal + borrowerPrincipal - principal, "tracked balance debited");

        // Repay internally
        vm.prank(borrower);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrower);
        lifecycle.repay(agreementId);

        (uint256 borrowerFinal, uint256 totalFinal, uint256 trackedFinal,,) = views.poolState(1, borrowerKey);
        (uint256 lenderFinal,, , ,) = views.poolState(1, lenderKey);
        // Principals unchanged; tracked restored
        assertEq(borrowerFinal, borrowerPrincipal, "borrower principal restored");
        assertEq(lenderFinal, lenderPrincipal, "lender principal unchanged");
        assertEq(trackedFinal, totalFinal, "tracked aligns after repayment");
    }
}

/// @notice Feature: multi-pool-position-nfts, Property 5: Default Distribution Hierarchy
/// @notice Validates: Requirements 5.5, 5.6
contract DirectDefaultDistributionHierarchyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    address internal treasury = address(0xBEEF);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("A", "A", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 1000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(treasury, 6667);
        harness.setActiveCreditShare(0);
    }

    function _mintPositions(uint256 lenderPrincipal, uint256 borrowerPrincipal)
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lender, 1);
        borrowerPos = nft.mint(borrower, 1);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);
        harness.addPoolMember(1, address(asset), lenderKey, lenderPrincipal, true);
        harness.addPoolMember(1, address(asset), borrowerKey, borrowerPrincipal, true);
    }

    function testProperty_DefaultDistributionHierarchy() public {
        uint256 lenderPrincipal = 200 ether;
        uint256 borrowerPrincipal = 80 ether;
        uint256 principal = 100 ether;
        uint256 collateralLock = 50 ether;

        (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey) =
            _mintPositions(lenderPrincipal, borrowerPrincipal);

        DirectTypes.DirectOfferParams memory offer = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: principal,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: collateralLock,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lender);
        uint256 offerId = offers.postOffer(offer);
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        vm.warp(block.timestamp + 2 days);
        lifecycle.recover(agreementId);

        (uint256 lenderAfter,, , ,) = views.poolState(1, lenderKey);
        (uint256 borrowerAfter,, , ,) = views.poolState(1, borrowerKey);
        (uint256 protocolAfter,, , ,) = views.poolState(1, LibPositionHelpers.systemPositionKey(treasury));

        uint256 lenderShare = (collateralLock * 1000) / 10_000;
        uint256 remainder = collateralLock - lenderShare;
        (uint256 protocolShare,,) = DirectTestUtils.previewSplit(remainder, 6667, 0, true);

        // Collateral distribution priority: protocol -> fee index -> lender; lender absorbs shortfall
        assertEq(protocolAfter, protocolShare, "protocol receives first share");
        assertEq(lenderAfter, lenderPrincipal - principal + lenderShare, "lender recovers share after principal reduction");
        assertEq(borrowerAfter, borrowerPrincipal - collateralLock, "borrower collateral applied");

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Defaulted), "agreement defaulted");
    }
}

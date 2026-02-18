// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {LibPoints} from "../../../src/libraries/LibPoints.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "../DirectTestUtils.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

/// @notice Property: Direct accept operator calls credit points to position owner
/// @notice Validates: point-system requirements 2.4, 2.5, 7.2
contract DirectPointsRecipientPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal operator = address(0x0B0);
    address internal protocolTreasury = address(0xF00D);

    uint256 internal constant ACCEPT_POINTS = 17;

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 7000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(7000, 1000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(7000, 0));
        harness.setPointsPerAction(LibPoints.ACTION_DIRECT_ACCEPT, ACCEPT_POINTS);
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_AcceptOfferOperatorAccruesToOwner() public {
        vm.warp(200 days);

        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeMinter();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        vm.prank(borrowerOwner);
        nft.approve(operator, borrowerPositionId);

        uint256 ownerPointsBefore = harness.pointsBalance(borrowerOwner);
        uint256 operatorPointsBefore = harness.pointsBalance(operator);

        vm.prank(operator);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId, 0);

        assertEq(harness.pointsBalance(borrowerOwner), ownerPointsBefore + ACCEPT_POINTS);
        assertEq(harness.pointsBalance(operator), operatorPointsBefore);
        assertEq(views.getAgreement(agreementId).borrower, borrowerOwner);
    }
}

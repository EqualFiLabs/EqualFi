// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// **Feature: active-credit-index, Property 9: Settlement Operation Ordering**
/// Validates: Requirements 4.3, 7.1, 7.2
/// **Feature: active-credit-index, Property 15/19: Lifecycle State Management & Reset on Zero Exposure**
/// Validates: Requirements 7.3, 7.4, 2.5, 3.5
contract ActiveCreditSettlementPropertyTest is DirectDiamondTestBase {
    MockERC20 internal assetA;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        assetA = new MockERC20("AssetA", "A", 18, 2_000_000 ether);
        harness.setTreasuryShare(protocolTreasury, 0);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);

        assetA.mint(address(diamond), 1_000_000 ether);
        assetA.mint(lenderOwner, 500_000 ether);
        assetA.mint(borrowerOwner, 500_000 ether);
        vm.warp(10 days);
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function _mintPositionsSameAsset(uint256 lenderPrincipal, uint256 borrowerPrincipal)
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lenderOwner, 1);
        borrowerPos = nft.mint(borrowerOwner, 1);
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);
        harness.addPoolMember(1, address(assetA), lenderKey, lenderPrincipal, true);
        harness.addPoolMember(1, address(assetA), borrowerKey, borrowerPrincipal, true);
        vm.prank(lenderOwner);
        assetA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        assetA.approve(address(diamond), type(uint256).max);
        _finalizeMinter();
    }

    function _basicOffer(uint256 lenderPos, uint256 principal) internal pure returns (DirectTypes.DirectOfferParams memory) {
        return DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(0), // replaced by caller
            borrowAsset: address(0),     // replaced by caller
            principal: principal,
            aprBps: 0,
            durationSeconds: 30 days,
            collateralLockAmount: principal / 2,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });
    }

    function testProperty_SettlementOrderingOnIncrementalBorrow() public {
        (uint256 lenderPos, uint256 borrowerPos,, bytes32 borrowerKey) = _mintPositionsSameAsset(800 ether, 400 ether);

        DirectTypes.DirectOfferParams memory params1 = _basicOffer(lenderPos, 150 ether);
        params1.collateralAsset = address(assetA);
        params1.borrowAsset = address(assetA);

        vm.prank(lenderOwner);
        uint256 offer1 = offers.postOffer(params1);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offer1, borrowerPos);

        uint256 snapshotBefore = views.activeDebtState(1, borrowerKey).indexSnapshot;

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE);
        harness.accrueActive(1, 20 ether);
        uint256 indexAfterAccrual = views.poolActiveCreditIndex(1);
        uint256 delta = indexAfterAccrual - snapshotBefore;

        DirectTypes.DirectOfferParams memory params2 = _basicOffer(lenderPos, 50 ether);
        params2.collateralAsset = address(assetA);
        params2.borrowAsset = address(assetA);

        vm.prank(lenderOwner);
        uint256 offer2 = offers.postOffer(params2);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offer2, borrowerPos);

        uint256 expectedYield = Math.mulDiv(
            params1.principal + params1.collateralLockAmount,
            delta,
            LibActiveCreditIndex.INDEX_SCALE
        );
        assertEq(views.accruedYield(1, borrowerKey), expectedYield, "settle before dilution preserves yield");

        Types.ActiveCreditState memory state = views.activeDebtState(1, borrowerKey);
        assertEq(state.principal, params1.principal + params2.principal, "principal aggregated post-accept");
        assertEq(state.indexSnapshot, views.poolActiveCreditIndex(1), "checkpoint updated post-settle");
    }

    function testProperty_RepaySettlesAndResetsActiveCredit() public {
        (uint256 lenderPos, uint256 borrowerPos,, bytes32 borrowerKey) = _mintPositionsSameAsset(700 ether, 300 ether);
        DirectTypes.DirectOfferParams memory params = _basicOffer(lenderPos, 120 ether);
        params.collateralAsset = address(assetA);
        params.borrowAsset = address(assetA);

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        uint256 snapshotBefore = views.activeDebtState(1, borrowerKey).indexSnapshot;
        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE);
        harness.accrueActive(1, 15 ether);
        uint256 delta = views.poolActiveCreditIndex(1) - snapshotBefore;

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        uint256 expectedYield = Math.mulDiv(
            params.principal + params.collateralLockAmount,
            delta,
            LibActiveCreditIndex.INDEX_SCALE
        );
        assertEq(views.accruedYield(1, borrowerKey), expectedYield, "repay settles pending active credit");

        Types.ActiveCreditState memory state = views.activeDebtState(1, borrowerKey);
        assertEq(state.principal, 0, "principal cleared on zero exposure");
        assertEq(state.startTime, 0, "start time reset on zero exposure");
        assertEq(state.indexSnapshot, 0, "index snapshot reset on zero exposure");
    }
}

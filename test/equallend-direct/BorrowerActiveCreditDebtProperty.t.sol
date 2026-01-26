// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// **Feature: active-credit-index, Property 7: Borrower Same-Asset Debt Inclusion and Cross-Asset Exclusion**
/// Validates: Requirements 3.1, 3.2
contract BorrowerActiveCreditDebtPropertyTest is DirectDiamondTestBase {
    MockERC20 internal assetA;
    MockERC20 internal assetB;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        assetA = new MockERC20("AssetA", "A", 18, 2_000_000 ether);
        assetB = new MockERC20("AssetB", "B", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, 0);

        assetA.mint(address(diamond), 1_000_000 ether);
        assetB.mint(address(diamond), 1_000_000 ether);
        assetA.mint(lenderOwner, 500_000 ether);
        assetA.mint(borrowerOwner, 500_000 ether);
        assetB.mint(borrowerOwner, 500_000 ether);
        vm.warp(50 days);
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

    function _mintPositionsCrossAsset(uint256 lenderPrincipal, uint256 borrowerPrincipal)
        internal
        returns (uint256 lenderPos, uint256 borrowerPos, bytes32 lenderKey, bytes32 borrowerKey)
    {
        lenderPos = nft.mint(lenderOwner, 1);
        borrowerPos = nft.mint(borrowerOwner, 2);
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);
        harness.addPoolMember(1, address(assetA), lenderKey, lenderPrincipal, true);
        harness.addPoolMember(2, address(assetB), borrowerKey, borrowerPrincipal, true);
        vm.prank(lenderOwner);
        assetA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        assetB.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        assetA.approve(address(diamond), type(uint256).max);
        _finalizeMinter();
    }

    function testProperty_SameAssetDebtEarnsActiveCredit() public {
        (uint256 lenderPos, uint256 borrowerPos,, bytes32 borrowerKey) =
            _mintPositionsSameAsset(500 ether, 200 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(assetA),
            borrowAsset: address(assetA),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 30 days,
            collateralLockAmount: 50 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        (uint256 locked,,) = views.directBalances(borrowerKey, params.collateralPoolId);
        (uint256 borrowerPrincipal,, uint256 trackedAfter,, uint256 activeCreditIndexBefore) =
            views.poolState(1, borrowerKey);
        assertEq(locked, params.collateralLockAmount, "collateral locked");

        Types.ActiveCreditState memory stateAfterAccept = views.activeDebtState(1, borrowerKey);
        assertEq(stateAfterAccept.principal, params.principal, "active debt principal tracked");
        uint256 expectedBase = params.principal * 2 + params.collateralLockAmount;
        assertEq(views.poolActiveCreditTotal(1), expectedBase, "pool active credit base tracked");

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE);
        harness.accrueActive(1, 10 ether);
        harness.settleActive(1, borrowerKey);

        uint256 expectedYield = 6 ether; // borrower debt + collateral lock share of total base
        assertEq(views.accruedYield(1, borrowerKey), expectedYield, "same-asset debt accrues active credit yield");

        (,, uint256 trackedAfterSettle,, uint256 activeCreditIndexAfter) = views.poolState(1, borrowerKey);
        assertEq(trackedAfterSettle, trackedAfter + 10 ether, "tracked includes accrued");
        assertGt(activeCreditIndexAfter, activeCreditIndexBefore, "active credit index increments");
        // Silence unused variable warning for agreement/principal
        agreementId;
        borrowerPrincipal;
    }

    function testProperty_CrossAssetDebtExcludedFromActiveCredit() public {
        (uint256 lenderPos, uint256 borrowerPos,, bytes32 borrowerKey) =
            _mintPositionsCrossAsset(500 ether, 200 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(assetB),
            borrowAsset: address(assetA),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 30 days,
            collateralLockAmount: 50 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPos);

        Types.ActiveCreditState memory stateAfterAccept = views.activeDebtState(2, borrowerKey);
        assertEq(stateAfterAccept.principal, 0, "cross-asset debt excluded from active credit");
    }
}

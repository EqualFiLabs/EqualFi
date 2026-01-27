// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// forge-config: default.optimizer = false

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

/// @notice Integration workflow tests: post→accept→repay and post→accept→recover
contract DirectIntegrationWorkflowTest is DirectDiamondTestBase {
    MockERC20 internal tokenA; // lender underlying / borrow asset
    MockERC20 internal tokenB; // borrower underlying / collateral asset

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    address internal thirdParty = address(0xC0FFEE);
    uint16 internal treasurySplitBps;
    uint16 internal activeSplitBps;

    struct PositionContext {
        uint256 lenderPos;
        uint256 borrowerPos;
        bytes32 lenderKey;
        bytes32 borrowerKey;
    }

    struct DefaultFlowState {
        uint256 agreementId;
        uint256 collateralLockAmount;
        uint256 lenderPrincipalBefore;
        uint256 borrowerPrincipalBefore;
        uint256 lenderPrincipalCollateralBefore;
        uint256 protocolPrincipalCollateralBefore;
        uint256 defaultAcceptedAt;
    }

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 2_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        treasurySplitBps = DirectTestUtils.treasurySplitFromLegacy(5000, 2000);
        activeSplitBps = DirectTestUtils.activeSplitFromLegacy(5000, 0);
        harness.setTreasuryShare(protocolTreasury, treasurySplitBps);
        harness.setActiveCreditShare(activeSplitBps);
    }

    function testIntegration_EndToEndRepayAndRecover() public {
        vm.warp(10 days);
        PositionContext memory ctx = _setupWorkflowContext();
        _runRepayFlow(ctx);
        _runDefaultFlow(ctx);
    }

    /// @dev Deterministic happy-path for gas reporting: post → accept → repay.
    function test_gas_DirectOfferRepayFlow() public {
        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        harness.seedPoolWithMembership(1, address(tokenA), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(tokenB), borrowerKey, 150 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.transfer(borrowerOwner, 200 ether);
        vm.prank(borrowerOwner);
        tokenB.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory offerRepay = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 50 ether,
            aprBps: 1200,
            durationSeconds: 3 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(offerRepay);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPos);

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);
    }

    function _setupWorkflowContext() internal returns (PositionContext memory ctx) {
        ctx.lenderPos = nft.mint(lenderOwner, 1);
        ctx.borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        ctx.lenderKey = nft.getPositionKey(ctx.lenderPos);
        ctx.borrowerKey = nft.getPositionKey(ctx.borrowerPos);

        harness.seedPoolWithMembership(1, address(tokenA), ctx.lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(tokenB), ctx.borrowerKey, 200 ether, true);

        tokenA.transfer(lenderOwner, 500 ether);
        tokenA.transfer(borrowerOwner, 100 ether);
        tokenB.transfer(lenderOwner, 100 ether);
        tokenB.transfer(borrowerOwner, 150 ether);
        vm.prank(lenderOwner);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        tokenA.approve(address(diamond), type(uint256).max);
    }

    function _runRepayFlow(PositionContext memory ctx) internal {
        DirectTypes.DirectOfferParams memory offerRepay = _repayOfferParams(ctx.lenderPos);
        uint256 agreementRepayId = _postAndAccept(offerRepay, ctx.borrowerPos);

        {
            (uint256 borrowerLocked, uint256 borrowerLent) = views.getPositionDirectState(ctx.borrowerPos, 2);
            assertEq(borrowerLocked, offerRepay.collateralLockAmount, "collateral locked");
            assertEq(borrowerLent, 0);
            (, uint256 lenderLent) = views.getPositionDirectState(ctx.lenderPos, 1);
            assertEq(lenderLent, offerRepay.principal, "lender lent tracked");
        }

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementRepayId);
        {
            (uint256 borrowerLocked, uint256 borrowerLent) = views.getPositionDirectState(ctx.borrowerPos, 2);
            (, uint256 lenderLent) = views.getPositionDirectState(ctx.lenderPos, 1);
            assertEq(borrowerLocked, 0, "collateral unlocked on repay");
            assertEq(lenderLent, 0, "lender lent cleared on repay");
        }
        assertEq(
            uint256(views.getAgreement(agreementRepayId).status),
            uint256(DirectTypes.DirectStatus.Repaid),
            "repay status"
        );
    }

    function _runDefaultFlow(PositionContext memory ctx) internal {
        DirectTypes.DirectOfferParams memory offerDefault = _defaultOfferParams(ctx.lenderPos);
        DefaultFlowState memory st;
        st.agreementId = _postAndAccept(offerDefault, ctx.borrowerPos);
        st.defaultAcceptedAt = block.timestamp;
        st.collateralLockAmount = offerDefault.collateralLockAmount;

        vm.warp(DirectTestUtils.dueTimestamp(st.defaultAcceptedAt, offerDefault.durationSeconds) + 1 days);
        st.lenderPrincipalBefore = views.getUserPrincipal(1, ctx.lenderKey);
        st.borrowerPrincipalBefore = views.getUserPrincipal(2, ctx.borrowerKey);
        st.lenderPrincipalCollateralBefore = views.getUserPrincipal(2, ctx.lenderKey);
        st.protocolPrincipalCollateralBefore =
            views.getUserPrincipal(2, LibPositionHelpers.systemPositionKey(protocolTreasury));

        vm.prank(thirdParty);
        lifecycle.recover(st.agreementId);

        assertEq(
            uint256(views.getAgreement(st.agreementId).status),
            uint256(DirectTypes.DirectStatus.Defaulted),
            "defaulted status"
        );

        uint256 borrowerPrincipalAfter = views.getUserPrincipal(2, ctx.borrowerKey);
        uint256 lenderShare = (st.collateralLockAmount * 8000) / 10_000;
        uint256 remainder = st.collateralLockAmount - lenderShare;
        (uint256 protocolShare,,) = DirectTestUtils.previewSplit(remainder, treasurySplitBps, activeSplitBps, true);

        assertEq(
            views.getUserPrincipal(1, ctx.lenderKey),
            st.lenderPrincipalBefore,
            "lender principal unchanged after default"
        );
        uint256 expectedBorrower =
            st.borrowerPrincipalBefore > st.collateralLockAmount ? st.borrowerPrincipalBefore - st.collateralLockAmount : 0;
        assertEq(borrowerPrincipalAfter, expectedBorrower, "borrower collateral deducted");
        assertEq(
            views.getUserPrincipal(2, ctx.lenderKey),
            st.lenderPrincipalCollateralBefore + lenderShare,
            "lender credited in collateral pool"
        );
        assertEq(
            views.getUserPrincipal(2, LibPositionHelpers.systemPositionKey(protocolTreasury)),
            st.protocolPrincipalCollateralBefore + protocolShare,
            "protocol credited in collateral pool"
        );

        {
            (uint256 borrowerLocked, uint256 borrowerLent) = views.getPositionDirectState(ctx.borrowerPos, 2);
            (, uint256 lenderLent) = views.getPositionDirectState(ctx.lenderPos, 1);
            assertEq(borrowerLocked, 0, "locked cleared after recover");
            assertEq(lenderLent, 0, "lent cleared after recover");
        }
    }

    function _repayOfferParams(uint256 lenderPos) internal view returns (DirectTypes.DirectOfferParams memory offerRepay) {
        offerRepay.lenderPositionId = lenderPos;
        offerRepay.lenderPoolId = 1;
        offerRepay.collateralPoolId = 2;
        offerRepay.collateralAsset = address(tokenB);
        offerRepay.borrowAsset = address(tokenA);
        offerRepay.principal = 80 ether;
        offerRepay.aprBps = 1200;
        offerRepay.durationSeconds = 3 days;
        offerRepay.collateralLockAmount = 30 ether;
        offerRepay.allowEarlyRepay = true;
        offerRepay.allowEarlyExercise = false;
        offerRepay.allowLenderCall = false;
    }

    function _defaultOfferParams(uint256 lenderPos)
        internal
        view
        returns (DirectTypes.DirectOfferParams memory offerDefault)
    {
        offerDefault.lenderPositionId = lenderPos;
        offerDefault.lenderPoolId = 1;
        offerDefault.collateralPoolId = 2;
        offerDefault.collateralAsset = address(tokenB);
        offerDefault.borrowAsset = address(tokenA);
        offerDefault.principal = 60 ether;
        offerDefault.aprBps = 1000;
        offerDefault.durationSeconds = 1 days;
        offerDefault.collateralLockAmount = 40 ether;
        offerDefault.allowEarlyRepay = false;
        offerDefault.allowEarlyExercise = false;
        offerDefault.allowLenderCall = false;
    }

    function _postAndAccept(DirectTypes.DirectOfferParams memory offer, uint256 borrowerPos)
        internal
        returns (uint256 agreementId)
    {
        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(offer);
        vm.prank(borrowerOwner);
        agreementId = agreements.acceptOffer(offerId, borrowerPos);
    }
}

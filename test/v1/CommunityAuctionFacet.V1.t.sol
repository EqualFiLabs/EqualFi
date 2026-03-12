// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    CommunityAuction_AlreadyFinalized,
    CommunityAuctionFacet,
    CommunityAuction_AlreadyStarted,
    CommunityAuction_InvalidRatio,
    CommunityAuction_NotActive,
    CommunityAuction_NotCreator,
    CommunityAuction_NotExpired,
    CommunityAuction_NotParticipant,
    CommunityAuction_Paused,
    CommunityAuction_StableModeDisabled
} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {CommunityAuctionViewFacet} from "../../src/views/CommunityAuctionViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockCommunityTokenV1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CommunityAuctionV1Harness is CommunityAuctionFacet, CommunityAuctionViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setStableModeEnabled(bool enabled) external {
        LibDerivativeStorage.derivativeStorage().config.stableModeEnabled = enabled;
    }

    function setCommunityMakerShareBps(uint16 bps) external {
        LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps = bps;
    }

    function setCommunityAuctionPaused(bool paused) external {
        LibDerivativeStorage.derivativeStorage().communityAuctionPaused = paused;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setFeeSplits(uint16 treasuryShareBps, uint16 activeCreditShareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = treasuryShareBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = activeCreditShareBps;
        store.activeCreditShareConfigured = true;
    }

    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked)
        external
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;

        if (tracked > 0) {
            MockCommunityTokenV1(underlying).mint(address(this), tracked);
        }

        if (p.feeIndex == 0) p.feeIndex = LibFeeIndex.INDEX_SCALE;
        if (p.maintenanceIndex == 0) p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        if (p.activeCreditIndex == 0) p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function makerPosition(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (DerivativeTypes.MakerPosition memory)
    {
        return LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
    }

    function directLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function yieldReserve(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function userAccruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function treasuryFeesByPool(uint256 pid) external view returns (uint256) {
        return LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[pid];
    }
}

contract CommunityAuctionFacetV1Test is Test {
    address internal constant MAKER = address(0x1111);
    address internal constant JOINER = address(0x2222);
    address internal constant TAKER = address(0x3333);
    address internal constant STRANGER = address(0x4444);

    CommunityAuctionV1Harness internal harness;
    PositionNFT internal nft;
    MockCommunityTokenV1 internal tokenA;
    MockCommunityTokenV1 internal tokenB;

    event CommunityAuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 indexed creatorPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        address tokenA,
        address tokenB,
        uint256 reserveA,
        uint256 reserveB,
        uint64 startTime,
        uint64 endTime,
        uint16 feeBps,
        DerivativeTypes.FeeAsset feeAsset,
        DerivativeTypes.InvariantMode invariantMode
    );

    event CommunityAuctionSwapped(
        uint256 indexed auctionId,
        address indexed swapper,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );

    event CommunityAuctionFinalized(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 reserveA,
        uint256 reserveB
    );

    event CommunityAuctionCancelled(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 reserveA,
        uint256 reserveB
    );

    function setUp() public {
        harness = new CommunityAuctionV1Harness();
        harness.setStableModeEnabled(true);
        harness.setCommunityMakerShareBps(10_000);
        harness.setTreasury(address(0xD00D));
        harness.setFeeSplits(1_000, 7_000);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        tokenA = new MockCommunityTokenV1("TokenA", "A", 18);
        tokenB = new MockCommunityTokenV1("TokenB", "B", 18);
    }

    function test_createJoinSwapLeaveAndFinalize_flow() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedPosition(MAKER, 6e18, 12e18);
        (uint256 joinerPositionId, bytes32 joinerKey) = _seedPosition(JOINER, 4e18, 8e18);

        vm.expectEmit(true, true, true, true);
        emit CommunityAuctionCreated(
            1,
            makerKey,
            makerPositionId,
            1,
            2,
            address(tokenA),
            address(tokenB),
            2e18,
            4e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            100,
            DerivativeTypes.FeeAsset.TokenIn,
            DerivativeTypes.InvariantMode.Volatile
        );
        vm.prank(MAKER);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        assertEq(harness.getTotalMakers(auctionId), 1);
        assertEq(harness.directLent(makerKey, 1), 2e18);
        assertEq(harness.directLent(makerKey, 2), 4e18);

        uint256 joinAmountA = 1e18;
        uint256 joinAmountB = harness.previewJoin(auctionId, joinAmountA);
        assertEq(joinAmountB, 2e18);

        vm.prank(JOINER);
        harness.joinCommunityAuction(auctionId, joinerPositionId, joinAmountA, joinAmountB);

        assertEq(harness.getTotalMakers(auctionId), 2);
        (uint256 joinerShare,,) = harness.getMakerShare(auctionId, joinerKey);
        assertGt(joinerShare, 0);

        uint256 amountIn = 1e18;
        (uint256 previewOut, uint256 previewFee) = harness.previewCommunitySwap(auctionId, address(tokenA), amountIn);
        assertGt(previewOut, 0);
        assertGt(previewFee, 0);

        tokenA.mint(TAKER, amountIn);
        vm.prank(TAKER);
        tokenA.approve(address(harness), amountIn);

        vm.expectEmit(true, true, false, true);
        emit CommunityAuctionSwapped(auctionId, TAKER, address(tokenA), amountIn, previewOut, previewFee, TAKER);
        vm.prank(TAKER);
        uint256 amountOut = harness.swapExactIn(auctionId, address(tokenA), amountIn, amountIn, previewOut, TAKER);
        assertEq(amountOut, previewOut);

        vm.prank(MAKER);
        (uint256 pendingMakerFeesA,) = harness.claimFees(auctionId, makerPositionId);
        assertGt(pendingMakerFeesA, 0);

        vm.prank(JOINER);
        (uint256 withdrawnA, uint256 withdrawnB,,) = harness.leaveCommunityAuction(auctionId, joinerPositionId);
        assertGt(withdrawnA, 0);
        assertGt(withdrawnB, 0);
        assertEq(harness.getTotalMakers(auctionId), 1);

        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotExpired.selector, auctionId));
        harness.finalizeAuction(auctionId);

        DerivativeTypes.CommunityAuction memory beforeFinalize = harness.getCommunityAuction(auctionId);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, false, true);
        emit CommunityAuctionFinalized(auctionId, makerKey, beforeFinalize.reserveA, beforeFinalize.reserveB);
        harness.finalizeAuction(auctionId);

        DerivativeTypes.CommunityAuction memory done = harness.getCommunityAuction(auctionId);
        assertFalse(done.active);
        assertTrue(done.finalized);
    }

    function test_claimFees_exactAccounting_forSingleMaker() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedPosition(MAKER, 6e18, 12e18);
        harness.setCommunityMakerShareBps(10_000);

        vm.prank(MAKER);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 1e18,
                reserveB: 1e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 amountIn = 1e18;
        (uint256 previewOut, uint256 previewFee) = harness.previewCommunitySwap(auctionId, address(tokenA), amountIn);
        assertGt(previewOut, 0);
        assertGt(previewFee, 0);

        tokenA.mint(TAKER, amountIn);
        vm.prank(TAKER);
        tokenA.approve(address(harness), amountIn);
        vm.prank(TAKER);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, amountIn, previewOut, TAKER);

        DerivativeTypes.CommunityAuction memory beforeClaim = harness.getCommunityAuction(auctionId);
        uint256 reserveABefore = beforeClaim.reserveA;
        uint256 yieldReserveABefore = harness.yieldReserve(1);
        uint256 trackedABefore = harness.trackedBalance(1);
        uint256 accruedYieldBefore = harness.userAccruedYield(1, makerKey);

        vm.prank(MAKER);
        (uint256 feesA, uint256 feesB) = harness.claimFees(auctionId, makerPositionId);
        assertEq(feesA, previewFee);
        assertEq(feesB, 0);

        DerivativeTypes.CommunityAuction memory afterClaim = harness.getCommunityAuction(auctionId);
        assertEq(afterClaim.reserveA, reserveABefore - feesA);
        assertEq(afterClaim.reserveB, beforeClaim.reserveB);
        assertEq(harness.yieldReserve(1), yieldReserveABefore + feesA);
        assertEq(harness.trackedBalance(1), trackedABefore + feesA);
        assertEq(harness.userAccruedYield(1, makerKey), accruedYieldBefore + feesA);

        vm.prank(MAKER);
        (feesA, feesB) = harness.claimFees(auctionId, makerPositionId);
        assertEq(feesA, 0);
        assertEq(feesB, 0);
    }

    function test_leaveCommunityAuction_finalMakerReservesProtocolYieldAndClearsBuckets() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedPosition(MAKER, 6e18, 12e18);
        harness.setCommunityMakerShareBps(0);

        vm.prank(MAKER);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 amountIn = 1e18;
        (uint256 previewOut, uint256 previewFee) = harness.previewCommunitySwap(auctionId, address(tokenA), amountIn);
        uint256 expectedTreasury = (previewFee * 1_000) / 10_000;
        uint256 expectedActive = (previewFee * 7_000) / 10_000;
        uint256 expectedIndex = previewFee - expectedTreasury - expectedActive;

        tokenA.mint(TAKER, amountIn);
        vm.prank(TAKER);
        tokenA.approve(address(harness), amountIn);
        vm.prank(TAKER);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, amountIn, previewOut, TAKER);

        DerivativeTypes.CommunityAuction memory afterSwap = harness.getCommunityAuction(auctionId);
        assertEq(afterSwap.treasuryFeeAAccrued, expectedTreasury);
        assertEq(afterSwap.indexFeeAAccrued, expectedIndex);
        assertEq(afterSwap.activeCreditFeeAAccrued, expectedActive);
        assertEq(afterSwap.treasuryFeeBAccrued, 0);
        assertEq(afterSwap.indexFeeBAccrued, 0);
        assertEq(afterSwap.activeCreditFeeBAccrued, 0);
        assertEq(harness.treasuryFeesByPool(1), expectedTreasury);

        (uint256 previewLeaveA, uint256 previewLeaveB,,) = harness.previewLeave(auctionId, makerKey);
        uint256 trackedABeforeLeave = harness.trackedBalance(1);
        uint256 trackedBBeforeLeave = harness.trackedBalance(2);
        uint256 principalABeforeLeave = harness.principalOf(1, makerKey);
        uint256 principalBBeforeLeave = harness.principalOf(2, makerKey);
        uint256 initialA = harness.makerPosition(auctionId, makerKey).initialContributionA;
        uint256 initialB = harness.makerPosition(auctionId, makerKey).initialContributionB;

        vm.prank(MAKER);
        (uint256 withdrawnA, uint256 withdrawnB, uint256 feesA, uint256 feesB) =
            harness.leaveCommunityAuction(auctionId, makerPositionId);
        assertEq(withdrawnA, previewLeaveA);
        assertEq(withdrawnB, previewLeaveB);
        assertEq(feesA, 0);
        assertEq(feesB, 0);

        DerivativeTypes.CommunityAuction memory done = harness.getCommunityAuction(auctionId);
        assertFalse(done.active);
        assertTrue(done.finalized);
        assertEq(done.totalShares, 0);
        assertEq(done.reserveA, 0);
        assertEq(done.reserveB, 0);
        assertEq(done.indexFeeAAccrued, 0);
        assertEq(done.activeCreditFeeAAccrued, 0);
        assertEq(done.indexFeeBAccrued, 0);
        assertEq(done.activeCreditFeeBAccrued, 0);

        uint256 expectedPrincipalA =
            withdrawnA >= initialA ? principalABeforeLeave + (withdrawnA - initialA) : principalABeforeLeave - (initialA - withdrawnA);
        uint256 expectedPrincipalB =
            withdrawnB >= initialB ? principalBBeforeLeave + (withdrawnB - initialB) : principalBBeforeLeave - (initialB - withdrawnB);
        assertEq(harness.principalOf(1, makerKey), expectedPrincipalA);
        assertEq(harness.principalOf(2, makerKey), expectedPrincipalB);
        assertEq(
            harness.trackedBalance(1),
            trackedABeforeLeave
                + (withdrawnA >= initialA ? (withdrawnA - initialA) : 0)
                - (withdrawnA < initialA ? (initialA - withdrawnA) : 0)
        );
        assertEq(
            harness.trackedBalance(2),
            trackedBBeforeLeave
                + (withdrawnB >= initialB ? (withdrawnB - initialB) : 0)
                - (withdrawnB < initialB ? (initialB - withdrawnB) : 0)
        );
    }

    function test_joinSwapLeaveFinalize_guards_forInactiveFinalizedAndStartTime() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedPosition(MAKER, 6e18, 12e18);
        (uint256 joinerPositionId,) = _seedPosition(JOINER, 4e18, 8e18);

        vm.prank(MAKER);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp + 1 days),
                endTime: uint64(block.timestamp + 2 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        tokenA.mint(TAKER, 1e18);
        vm.prank(TAKER);
        tokenA.approve(address(harness), 1e18);
        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotActive.selector, auctionId));
        harness.swapExactIn(auctionId, address(tokenA), 1e18, 1e18, 0, TAKER);

        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotExpired.selector, auctionId));
        harness.finalizeAuction(auctionId);

        vm.prank(MAKER);
        harness.cancelCommunityAuction(auctionId);

        vm.prank(JOINER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotActive.selector, auctionId));
        harness.joinCommunityAuction(auctionId, joinerPositionId, 1e18, 2e18);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotActive.selector, auctionId));
        harness.swapExactIn(auctionId, address(tokenA), 1e18, 1e18, 0, TAKER);

        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotActive.selector, auctionId));
        harness.finalizeAuction(auctionId);

        vm.prank(MAKER);
        harness.leaveCommunityAuction(auctionId, makerPositionId);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_AlreadyFinalized.selector, auctionId));
        harness.leaveCommunityAuction(auctionId, makerPositionId);
        makerKey;
    }

    function test_cancelCommunityAuction_accessAndTiming() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedPosition(MAKER, 6e18, 12e18);
        vm.expectEmit(true, true, true, true);
        emit CommunityAuctionCreated(
            1,
            makerKey,
            makerPositionId,
            1,
            2,
            address(tokenA),
            address(tokenB),
            2e18,
            4e18,
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days),
            0,
            DerivativeTypes.FeeAsset.TokenIn,
            DerivativeTypes.InvariantMode.Volatile
        );
        vm.prank(MAKER);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp + 1 days),
                endTime: uint64(block.timestamp + 2 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotCreator.selector, makerKey));
        harness.cancelCommunityAuction(auctionId);

        vm.expectEmit(true, true, false, true);
        emit CommunityAuctionCancelled(auctionId, makerKey, 2e18, 4e18);
        vm.prank(MAKER);
        harness.cancelCommunityAuction(auctionId);

        DerivativeTypes.CommunityAuction memory cancelled = harness.getCommunityAuction(auctionId);
        assertFalse(cancelled.active);
        assertTrue(cancelled.finalized);

        (uint256 makerPositionId2,) = _seedPosition(address(0x5555), 6e18, 12e18);
        vm.prank(address(0x5555));
        uint256 startedAuctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId2,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        vm.prank(address(0x5555));
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_AlreadyStarted.selector, startedAuctionId));
        harness.cancelCommunityAuction(startedAuctionId);
    }

    function test_pauseStableAndJoinRatio_guards() public {
        harness.setCommunityAuctionPaused(true);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_Paused.selector));
        harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: 1,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 1e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        harness.setCommunityAuctionPaused(false);
        harness.setStableModeEnabled(false);

        (uint256 makerPositionId,) = _seedPosition(MAKER, 6e18, 12e18);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_StableModeDisabled.selector));
        harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Stable
            })
        );

        harness.setStableModeEnabled(true);
        (uint256 makerPositionId2,) = _seedPosition(address(0x6666), 6e18, 12e18);
        (uint256 joinerPositionId,) = _seedPosition(JOINER, 4e18, 8e18);

        vm.prank(address(0x6666));
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerPositionId2,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        vm.prank(JOINER);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_InvalidRatio.selector, 2e18, 3e18));
        harness.joinCommunityAuction(auctionId, joinerPositionId, 1e18, 3e18);
    }

    function _seedPosition(address owner, uint256 reserveA, uint256 reserveB)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        positionId = nft.mint(owner, 1);
        positionKey = nft.getPositionKey(positionId);
        harness.seedPool(1, address(tokenA), positionKey, reserveA + 3e18, reserveA + 3e18);
        harness.seedPool(2, address(tokenB), positionKey, reserveB + 3e18, reserveB + 3e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }
}

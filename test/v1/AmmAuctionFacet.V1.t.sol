// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    AmmAuctionFacet,
    AmmAuction_InvalidRatio,
    AmmAuction_NotActive,
    AmmAuction_Paused
} from "../../src/EqualX/AmmAuctionFacet.sol";
import {AmmAuctionViewFacet} from "../../src/views/AmmAuctionViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockAmmTokenV1 is ERC20 {
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

contract AmmAuctionV1Harness is AmmAuctionFacet, AmmAuctionViewFacet {
    function configureAccess(address owner_, address timelock_) external {
        LibDiamond.setContractOwner(owner_);
        LibAppStorage.s().timelock = timelock_;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setStableModeEnabled(bool enabled) external {
        LibDerivativeStorage.derivativeStorage().config.stableModeEnabled = enabled;
    }

    function setAmmMakerShareBps(uint16 bps) external {
        LibDerivativeStorage.derivativeStorage().config.ammMakerShareBps = bps;
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
            MockAmmTokenV1(underlying).mint(address(this), tracked);
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

    function directLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function activeAuctions(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, uint256 total) {
        return LibDerivativeStorage.auctionsGlobalPage(offset, limit);
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function treasuryFeesByPool(uint256 pid) external view returns (uint256) {
        return LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[pid];
    }

    function feeBucketsByAuction(uint256 auctionId)
        external
        view
        returns (uint256 indexFeeA, uint256 indexFeeB, uint256 activeFeeA, uint256 activeFeeB)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        return (
            ds.indexFeeAByAuction[auctionId],
            ds.indexFeeBByAuction[auctionId],
            ds.activeCreditFeeAByAuction[auctionId],
            ds.activeCreditFeeBByAuction[auctionId]
        );
    }
}

contract AmmAuctionFacetV1Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant MAKER = address(0x1111);
    address internal constant TAKER = address(0x2222);

    AmmAuctionV1Harness internal harness;
    PositionNFT internal nft;
    MockAmmTokenV1 internal tokenA;
    MockAmmTokenV1 internal tokenB;

    event AuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
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

    event AuctionSwapped(
        uint256 indexed auctionId,
        address indexed swapper,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );

    event AuctionFinalized(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 reserveA,
        uint256 reserveB,
        uint256 makerFeeA,
        uint256 makerFeeB
    );

    event AuctionCancelled(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 reserveA,
        uint256 reserveB,
        uint256 makerFeeA,
        uint256 makerFeeB
    );

    function setUp() public {
        harness = new AmmAuctionV1Harness();
        harness.configureAccess(OWNER, TIMELOCK);
        harness.setStableModeEnabled(true);
        harness.setAmmMakerShareBps(7_000);
        harness.setTreasury(address(0xD00D));
        harness.setFeeSplits(1_000, 7_000);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        tokenA = new MockAmmTokenV1("TokenA", "A", 18);
        tokenB = new MockAmmTokenV1("TokenB", "B", 18);
    }

    function test_setAmmPaused_accessAndCreateGuard() public {
        vm.prank(TAKER);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setAmmPaused(true);

        vm.prank(OWNER);
        harness.setAmmPaused(true);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: 1,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(AmmAuction_Paused.selector));
        harness.createAuction(params);
    }

    function test_createSwapThenFinalize_viaExpiryPath() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerPosition(MAKER, 4e18, 8e18);
        uint256 principalABefore = harness.principalOf(1, makerKey);
        uint256 principalBBefore = harness.principalOf(2, makerKey);
        uint256 totalDepositsABefore = harness.totalDeposits(1);
        uint256 totalDepositsBBefore = harness.totalDeposits(2);
        uint256 trackedABefore = harness.trackedBalance(1);
        uint256 trackedBBefore = harness.trackedBalance(2);

        vm.expectEmit(true, true, true, true);
        emit AuctionCreated(
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
            30,
            DerivativeTypes.FeeAsset.TokenIn,
            DerivativeTypes.InvariantMode.Volatile
        );
        vm.prank(MAKER);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerPositionId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        DerivativeTypes.AmmAuction memory created = harness.getAuction(auctionId);
        assertTrue(created.active);
        assertFalse(created.finalized);
        assertEq(harness.directLent(makerKey, 1), 2e18);
        assertEq(harness.directLent(makerKey, 2), 4e18);

        (uint256[] memory ids, uint256 total) = harness.activeAuctions(0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId);

        uint256 amountIn = 1e18;
        (uint256 previewOut, uint256 previewFee) = harness.previewSwap(auctionId, address(tokenA), amountIn);
        assertGt(previewOut, 0);
        assertGt(previewFee, 0);

        (uint256 expectedMakerFee, uint256 expectedTreasuryFee, uint256 expectedActiveFee, uint256 expectedIndexFee) =
            _computeExpectedFeeSplit(previewFee, 7_000, 1_000, 7_000);

        tokenA.mint(TAKER, amountIn);
        vm.prank(TAKER);
        tokenA.approve(address(harness), amountIn);

        vm.expectEmit(true, true, false, true);
        emit AuctionSwapped(auctionId, TAKER, address(tokenA), amountIn, previewOut, previewFee, TAKER);
        vm.prank(TAKER);
        (uint256 amountOut, bool finalizedBeforeExpiry) =
            harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, previewOut, TAKER);
        assertEq(amountOut, previewOut);
        assertFalse(finalizedBeforeExpiry);
        assertEq(tokenB.balanceOf(TAKER), amountOut);

        DerivativeTypes.AmmAuction memory afterSwap = harness.getAuction(auctionId);
        assertEq(afterSwap.makerFeeAAccrued, expectedMakerFee);
        assertEq(afterSwap.treasuryFeeAAccrued, expectedTreasuryFee);
        assertEq(afterSwap.makerFeeBAccrued, 0);
        assertEq(afterSwap.treasuryFeeBAccrued, 0);

        (uint256 indexFeeA, uint256 indexFeeB, uint256 activeFeeA, uint256 activeFeeB) = harness.feeBucketsByAuction(auctionId);
        assertEq(indexFeeA, expectedIndexFee);
        assertEq(indexFeeB, 0);
        assertEq(activeFeeA, expectedActiveFee);
        assertEq(activeFeeB, 0);

        assertEq(harness.treasuryFeesByPool(1), expectedTreasuryFee);

        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, false, true);
        emit AuctionFinalized(
            auctionId,
            makerKey,
            afterSwap.reserveA,
            afterSwap.reserveB,
            afterSwap.makerFeeAAccrued,
            afterSwap.makerFeeBAccrued
        );
        vm.prank(TAKER);
        (uint256 outAfterExpiry, bool finalized) =
            harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, 0, TAKER);
        assertEq(outAfterExpiry, 0);
        assertTrue(finalized);

        DerivativeTypes.AmmAuction memory done = harness.getAuction(auctionId);
        assertFalse(done.active);
        assertTrue(done.finalized);
        assertEq(harness.directLent(makerKey, 1), 0);
        assertEq(harness.directLent(makerKey, 2), 0);

        (indexFeeA, indexFeeB, activeFeeA, activeFeeB) = harness.feeBucketsByAuction(auctionId);
        assertEq(indexFeeA, 0);
        assertEq(indexFeeB, 0);
        assertEq(activeFeeA, 0);
        assertEq(activeFeeB, 0);

        uint256 expectedPrincipalDeltaA = amountIn - (previewFee - expectedMakerFee);
        uint256 expectedPrincipalDeltaB = previewOut;
        assertEq(harness.principalOf(1, makerKey), principalABefore + expectedPrincipalDeltaA);
        assertEq(harness.principalOf(2, makerKey), principalBBefore - expectedPrincipalDeltaB);
        assertEq(harness.totalDeposits(1), totalDepositsABefore + expectedPrincipalDeltaA);
        assertEq(harness.totalDeposits(2), totalDepositsBBefore - expectedPrincipalDeltaB);

        uint256 expectedTrackedDeltaA = amountIn - expectedTreasuryFee;
        assertEq(harness.trackedBalance(1), trackedABefore + expectedTrackedDeltaA);
        assertEq(harness.trackedBalance(2), trackedBBefore - expectedPrincipalDeltaB);

        (ids, total) = harness.activeAuctions(0, 10);
        assertEq(total, 0);
        assertEq(ids.length, 0);
    }

    function test_cancelAndAddLiquidity_guardsAndState() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerPosition(MAKER, 6e18, 12e18);
        uint256 principalABefore = harness.principalOf(1, makerKey);
        uint256 principalBBefore = harness.principalOf(2, makerKey);
        uint256 totalDepositsABefore = harness.totalDeposits(1);
        uint256 totalDepositsBBefore = harness.totalDeposits(2);
        uint256 trackedABefore = harness.trackedBalance(1);
        uint256 trackedBBefore = harness.trackedBalance(2);

        vm.expectEmit(true, true, true, true);
        emit AuctionCreated(
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
            0,
            DerivativeTypes.FeeAsset.TokenIn,
            DerivativeTypes.InvariantMode.Volatile
        );
        vm.prank(MAKER);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerPositionId,
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

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, TAKER, makerPositionId));
        harness.cancelAuction(auctionId);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(AmmAuction_InvalidRatio.selector, 2e18, 3e18));
        harness.addLiquidity(auctionId, 1e18, 3e18);

        vm.prank(MAKER);
        harness.addLiquidity(auctionId, 1e18, 2e18);

        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        assertEq(auction.reserveA, 3e18);
        assertEq(auction.reserveB, 6e18);
        assertEq(harness.directLent(makerKey, 1), 3e18);
        assertEq(harness.directLent(makerKey, 2), 6e18);

        vm.expectEmit(true, true, false, true);
        emit AuctionCancelled(auctionId, makerKey, 3e18, 6e18, 0, 0);
        vm.prank(MAKER);
        harness.cancelAuction(auctionId);

        DerivativeTypes.AmmAuction memory cancelled = harness.getAuction(auctionId);
        assertFalse(cancelled.active);
        assertTrue(cancelled.finalized);
        assertEq(harness.directLent(makerKey, 1), 0);
        assertEq(harness.directLent(makerKey, 2), 0);
        assertEq(harness.principalOf(1, makerKey), principalABefore);
        assertEq(harness.principalOf(2, makerKey), principalBBefore);
        assertEq(harness.totalDeposits(1), totalDepositsABefore);
        assertEq(harness.totalDeposits(2), totalDepositsBBefore);
        assertEq(harness.trackedBalance(1), trackedABefore);
        assertEq(harness.trackedBalance(2), trackedBBefore);

        (uint256 indexFeeA, uint256 indexFeeB, uint256 activeFeeA, uint256 activeFeeB) = harness.feeBucketsByAuction(auctionId);
        assertEq(indexFeeA, 0);
        assertEq(indexFeeB, 0);
        assertEq(activeFeeA, 0);
        assertEq(activeFeeB, 0);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(AmmAuction_NotActive.selector, auctionId));
        harness.finalizeAuction(auctionId);
    }

    function _computeExpectedFeeSplit(
        uint256 feeAmount,
        uint16 makerShareBps,
        uint16 treasuryShareBps,
        uint16 activeCreditShareBps
    ) internal pure returns (uint256 makerFee, uint256 treasuryFee, uint256 activeFee, uint256 indexFee) {
        makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        treasuryFee = (protocolFee * treasuryShareBps) / 10_000;
        activeFee = (protocolFee * activeCreditShareBps) / 10_000;
        indexFee = protocolFee - treasuryFee - activeFee;
    }

    function _seedMakerPosition(address owner, uint256 reserveA, uint256 reserveB)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        positionId = nft.mint(owner, 1);
        positionKey = nft.getPositionKey(positionId);
        harness.seedPool(1, address(tokenA), positionKey, reserveA + 2e18, reserveA + 2e18);
        harness.seedPool(2, address(tokenB), positionKey, reserveB + 2e18, reserveB + 2e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }
}

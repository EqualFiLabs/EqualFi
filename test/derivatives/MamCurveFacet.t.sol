// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {MamCurveViewFacet} from "../../src/views/MamCurveViewFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

error MamCurve_InvalidTime(uint64 startTime, uint64 duration);

contract MamCurveFacetTest is Test {
    MamCurveHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant MAX_PAST_START = 30 minutes;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal treasury = address(0xC0FFEE);

    function setUp() public {
        harness = new MamCurveHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);
        vm.warp(1 days);
    }

    function testCreateCurveLocksBase() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 1
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        (
            MamTypes.StoredCurve memory stored,
            LibDerivativeStorage.CurveData memory data,
            LibDerivativeStorage.CurvePricing memory pricing,
            LibDerivativeStorage.CurveImmutables memory immutables,
            bool baseIsA
        ) = harness.getCurve(curveId);
        assertTrue(stored.active);
        assertEq(stored.remainingVolume, 1e18);
        assertEq(data.makerPositionKey, positionKey);
        assertEq(pricing.startPrice, desc.startPrice);
        assertEq(immutables.maxVolume, desc.maxVolume);
        assertTrue(baseIsA);

        uint256 locked = harness.getDirectLocked(positionKey, 1);
        assertEq(locked, 1e18);
    }

    function testCreateCurveAllowsRecentPastStart() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp - 10 minutes),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 12
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);
        assertTrue(harness.getStoredCurve(curveId).active);
    }

    function testCreateCurveRejectsStalePastStart() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp - 31 minutes),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 13
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidTime.selector, desc.startTime, desc.duration));
        harness.createCurve(desc);
    }

    function testFuzz_CreateCurveStartWindow(bool past, uint256 offset) public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        offset = bound(offset, 0, 2 hours);
        uint64 startTime = past ? uint64(block.timestamp - offset) : uint64(block.timestamp + offset);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: startTime,
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: uint96(offset) + (past ? 1000 : 2000)
        });

        vm.prank(maker);
        if (past && offset > MAX_PAST_START) {
            vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidTime.selector, desc.startTime, desc.duration));
            harness.createCurve(desc);
        } else {
            uint256 curveId = harness.createCurve(desc);
            assertTrue(harness.getStoredCurve(curveId).active);
        }
    }

    function testFillCurveUpdatesBalancesAndFees() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 10e18;
        uint256 principalB = 10e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 7
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        tokenB.mint(taker, amountIn + 1e18);
        vm.prank(taker);
        tokenB.approve(address(harness), amountIn + 1e18);

        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 trackedQuoteBefore = harness.getTrackedBalance(2);

        vm.prank(taker);
        uint256 out = harness.executeCurveSwap(
            curveId,
            amountIn,
            1e18,
            uint64(block.timestamp + 1 days),
            taker
        );

        assertEq(out, 1e18);
        assertEq(tokenA.balanceOf(taker), 1e18);

        uint256 feeAmount = (amountIn * 100) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 treasuryFee = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;

        uint256 makerBaseAfter = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteAfter = harness.getUserPrincipal(2, positionKey);
        assertEq(makerBaseAfter, makerBaseBefore - 1e18);
        assertEq(makerQuoteAfter, makerQuoteBefore + amountIn + makerFee);

        uint256 trackedQuoteAfter = harness.getTrackedBalance(2);
        assertEq(trackedQuoteAfter, trackedQuoteBefore + amountIn + feeAmount - treasuryFee);
        assertEq(tokenB.balanceOf(treasury), treasuryFee);

        uint256 lockedAfter = harness.getDirectLocked(positionKey, 1);
        assertEq(lockedAfter, desc.maxVolume - 1e18);
    }

    function testUpdateCurveBumpsGeneration() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 5e18, 5e18);
        harness.seedPool(2, address(tokenB), positionKey, 5e18, 5e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp + 10),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 2
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 20),
            duration: 2 days
        });

        vm.prank(maker);
        harness.updateCurve(curveId, params);

        MamTypes.StoredCurve memory stored = harness.getStoredCurve(curveId);
        assertEq(stored.generation, 2);
    }

    function testCancelCurveUnlocksRemaining() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 5e18, 5e18);
        harness.seedPool(2, address(tokenB), positionKey, 5e18, 5e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 3
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        assertEq(harness.getDirectLocked(positionKey, 1), 1e18);

        vm.prank(maker);
        harness.cancelCurve(curveId);

        assertEq(harness.getDirectLocked(positionKey, 1), 0);
    }

    function testUpdateCurvesBatchBumpsGeneration() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 6e18, 6e18);
        harness.seedPool(2, address(tokenB), positionKey, 6e18, 6e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor[] memory descs = new MamTypes.CurveDescriptor[](2);
        descs[0] = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp + 10),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 11
        });
        descs[1] = descs[0];
        descs[1].salt = 12;

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        MamTypes.CurveUpdateParams[] memory params = new MamTypes.CurveUpdateParams[](2);
        params[0] = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 20),
            duration: 2 days
        });
        params[1] = MamTypes.CurveUpdateParams({
            startPrice: 4e18,
            endPrice: 3e18,
            startTime: uint64(block.timestamp + 30),
            duration: 3 days
        });

        uint256[] memory ids = new uint256[](2);
        ids[0] = firstId;
        ids[1] = firstId + 1;

        vm.prank(maker);
        harness.updateCurvesBatch(ids, params);

        MamTypes.StoredCurve memory stored0 = harness.getStoredCurve(firstId);
        MamTypes.StoredCurve memory stored1 = harness.getStoredCurve(firstId + 1);
        assertEq(stored0.generation, 2);
        assertEq(stored1.generation, 2);
    }

    function testCancelCurvesBatchUnlocksAll() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 6e18, 6e18);
        harness.seedPool(2, address(tokenB), positionKey, 6e18, 6e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor[] memory descs = new MamTypes.CurveDescriptor[](2);
        descs[0] = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 21
        });
        descs[1] = descs[0];
        descs[1].salt = 22;

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        assertEq(harness.getDirectLocked(positionKey, 1), 2e18);

        uint256[] memory ids = new uint256[](2);
        ids[0] = firstId;
        ids[1] = firstId + 1;

        vm.prank(maker);
        harness.cancelCurvesBatch(ids);

        assertEq(harness.getDirectLocked(positionKey, 1), 0);
    }

    function testCurveDiscoveryAndQuotes() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 3
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        (uint256[] memory activeIds, uint256 totalActive) = harness.getActiveCurves(0, 10);
        assertEq(totalActive, 1, "active count");
        assertEq(activeIds[0], curveId, "active id");

        (uint256[] memory pairIds, uint256 pairTotal) =
            harness.getCurvesByPair(address(tokenA), address(tokenB), 0, 10);
        assertEq(pairTotal, 1, "pair count");
        assertEq(pairIds[0], curveId, "pair id");

        (bool active, bool expired, uint128 remainingVolume, uint256 price,,,,,,) = harness.getCurveStatus(curveId);
        assertTrue(active, "status active");
        assertFalse(expired, "status not expired");
        assertEq(remainingVolume, 1e18, "remaining");
        assertGt(price, 0, "price");

        (uint256 amountOut, uint256 feeAmount,, uint128 remaining, bool ok) = harness.quoteCurveExactIn(curveId, 1e18);
        assertTrue(ok, "quote ok");
        assertEq(remaining, 1e18, "quote remaining");
        assertGt(amountOut, 0, "quote out");
        assertGt(feeAmount, 0, "quote fee");

        uint256[] memory curveIds = new uint256[](1);
        uint256[] memory amountIns = new uint256[](1);
        curveIds[0] = curveId;
        amountIns[0] = 1e18;
        (uint256[] memory outs, uint256[] memory fees, bool[] memory oks) =
            harness.quoteCurvesExactInBatch(curveIds, amountIns);
        assertEq(outs[0], amountOut, "batch out");
        assertEq(fees[0], feeAmount, "batch fee");
        assertTrue(oks[0], "batch ok");
    }

    function testExpireCurveClearsIndexes() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 11
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);
        assertEq(harness.getDirectLocked(positionKey, 1), 1e18, "locked");

        vm.warp(block.timestamp + 2 days);
        harness.expireCurve(curveId);

        (uint256[] memory activeIds, uint256 totalActive) = harness.getActiveCurves(0, 10);
        assertEq(totalActive, 0, "active cleared");
        assertEq(activeIds.length, 0, "active empty");

        (uint256[] memory pairIds, uint256 pairTotal) =
            harness.getCurvesByPair(address(tokenA), address(tokenB), 0, 10);
        assertEq(pairTotal, 0, "pair cleared");
        assertEq(pairIds.length, 0, "pair empty");
        assertEq(harness.getDirectLocked(positionKey, 1), 0, "unlocked");
    }
}

contract MamCurveHarness is MamCurveCreationFacet, MamCurveManagementFacet, MamCurveExecutionFacet, MamCurveViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.mamMakerShareBps = shareBps;
    }

    function getMakerShareBps() external view returns (uint16) {
        return LibDerivativeStorage.derivativeStorage().config.mamMakerShareBps;
    }

    function getTreasurySplitBps() external view returns (uint16) {
        return LibAppStorage.treasurySplitBps(LibAppStorage.s());
    }

    function getTreasuryAddress() external view returns (address) {
        return LibAppStorage.treasuryAddress(LibAppStorage.s());
    }

    function seedPool(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibFeeIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getStoredCurve(uint256 curveId) external view returns (MamTypes.StoredCurve memory) {
        return LibDerivativeStorage.derivativeStorage().curves[curveId];
    }
}

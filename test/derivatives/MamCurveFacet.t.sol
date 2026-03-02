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
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

error MamCurve_InvalidTime(uint64 startTime, uint64 duration);

contract MamCurveFacetTest is Test {
    event CurveFilled(
        uint256 indexed curveId,
        address indexed taker,
        address indexed recipient,
        uint256 amountIn,
        uint256 actualIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 remainingVolume
    );

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
            salt: 1,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 12,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 13,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: uint96(offset) + (past ? 1000 : 2000),
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 7,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);
        vm.startPrank(taker);
        tokenB.approve(address(harness), maxQuote);

        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 trackedQuoteBefore = harness.getTrackedBalance(2);

        uint256 out = harness.executeCurveSwap(curveId, amountIn, maxQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

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

    function test_curveSwapAccruesPointsToTaker() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        uint256 takerTokenId = nft.mint(taker, 1);
        bytes32 takerKey = nft.getPositionKey(takerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
        harness.setPointsPerAction(LibPoints.ACTION_SWAP_MAM_CURVE, 5);

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
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 999,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);
        vm.prank(taker);
        tokenB.approve(address(harness), maxQuote);

        assertEq(harness.pointsBalance(taker), 0);
        assertEq(harness.pointsBalanceForKey(takerKey), 0);
        vm.prank(taker);
        harness.executeCurveSwap(curveId, amountIn, maxQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        assertEq(harness.pointsBalance(taker), 0);
        assertEq(harness.pointsBalanceForKey(takerKey), 5);
    }

    function test_overCapMaxQuote_refundsExcess_withoutExtraOutput_nonFoT() public {
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
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 700,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 overCapQuote = totalQuote + 1e18;
        tokenB.mint(taker, overCapQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), overCapQuote);
        uint256 takerQuoteBefore = tokenB.balanceOf(taker);
        uint256 out =
            harness.executeCurveSwap(curveId, amountIn, overCapQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        uint256 takerSpent = takerQuoteBefore - tokenB.balanceOf(taker);
        vm.stopPrank();

        assertEq(out, 1e18, "no extra output from over-cap maxQuote");
        assertEq(tokenA.balanceOf(taker), 1e18, "base out");
        assertEq(takerSpent, totalQuote, "excess refunded to net quote");
    }

    function test_curveFilledActualIn_isNetQuote_forExactAndOverCap() public {
        uint256 makerTokenIdExact = nft.mint(maker, 1);
        bytes32 keyExact = nft.getPositionKey(makerTokenIdExact);
        uint256 makerTokenIdOver = nft.mint(maker, 1);
        bytes32 keyOver = nft.getPositionKey(makerTokenIdOver);

        uint256 principalA = 10e18;
        uint256 principalB = 10e18;
        harness.seedPool(1, address(tokenA), keyExact, principalA, principalA);
        harness.seedPool(2, address(tokenB), keyExact, principalB, principalB);
        harness.seedPool(3, address(tokenA), keyOver, principalA, principalA);
        harness.seedPool(4, address(tokenB), keyOver, principalB, principalB);
        harness.joinPool(keyExact, 1);
        harness.joinPool(keyExact, 2);
        harness.joinPool(keyOver, 3);
        harness.joinPool(keyOver, 4);

        MamTypes.CurveDescriptor memory exactDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyExact,
            makerPositionId: makerTokenIdExact,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 7050,
            profile: address(0),
            profileParams: bytes32(0)
        });
        MamTypes.CurveDescriptor memory overDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyOver,
            makerPositionId: makerTokenIdOver,
            poolIdA: 3,
            poolIdB: 4,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 7051,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.startPrank(maker);
        uint256 exactCurveId = harness.createCurve(exactDesc);
        uint256 overCurveId = harness.createCurve(overDesc);
        vm.stopPrank();

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(exactCurveId, amountIn);
        uint256 overCapQuote = totalQuote + 1e18;
        uint256 feeAmount = totalQuote - amountIn;
        uint256 expectedOut = 1e18;
        uint256 expectedRemaining = 1e18;
        tokenB.mint(taker, totalQuote + overCapQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote + overCapQuote);

        vm.expectEmit(true, true, true, true, address(harness));
        emit CurveFilled(exactCurveId, taker, taker, amountIn, totalQuote, expectedOut, feeAmount, expectedRemaining);
        harness.executeCurveSwap(exactCurveId, amountIn, totalQuote, expectedOut, uint64(block.timestamp + 1 days), taker);

        vm.expectEmit(true, true, true, true, address(harness));
        emit CurveFilled(overCurveId, taker, taker, amountIn, totalQuote, expectedOut, feeAmount, expectedRemaining);
        harness.executeCurveSwap(overCurveId, amountIn, overCapQuote, expectedOut, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();
    }

    function test_nativeBaseTokenDescriptor_isAccepted() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 3e18;
        uint256 principalB = 10e18;
        harness.seedPool(1, address(0), positionKey, principalA, 0);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 703,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);
        assertTrue(harness.getStoredCurve(curveId).active);
    }

    function test_nativeQuoteTokenDescriptor_isAccepted() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 10e18;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 704,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);
        assertTrue(harness.getStoredCurve(curveId).active);
    }

    function test_bothNativeDescriptor_reverts() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(0), positionKey, 3e18, 0);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 705,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSignature("MamCurve_InvalidDescriptor()"));
        harness.createCurve(desc);
    }

    function test_sameNonZeroTokensDescriptor_reverts() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenA), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenA),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 706,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSignature("MamCurve_InvalidDescriptor()"));
        harness.createCurve(desc);
    }

    function test_nativeDescriptor_revertsWhenPoolUnderlyingMismatch() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 707,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSignature("MamCurve_InvalidDescriptor()"));
        harness.createCurve(desc);
    }

    function testFuzz_overCapGrossPullDoesNotChangeOutputOrDebt(uint256 extraQuote) public {
        extraQuote = bound(extraQuote, 1, 10e18);

        uint256 makerTokenIdExact = nft.mint(maker, 1);
        bytes32 keyExact = nft.getPositionKey(makerTokenIdExact);
        uint256 makerTokenIdOver = nft.mint(maker, 1);
        bytes32 keyOver = nft.getPositionKey(makerTokenIdOver);

        uint256 principalA = 10e18;
        uint256 principalB = 10e18;
        harness.seedPool(1, address(tokenA), keyExact, principalA, principalA);
        harness.seedPool(2, address(tokenB), keyExact, principalB, principalB);
        harness.seedPool(3, address(tokenA), keyOver, principalA, principalA);
        harness.seedPool(4, address(tokenB), keyOver, principalB, principalB);
        harness.joinPool(keyExact, 1);
        harness.joinPool(keyExact, 2);
        harness.joinPool(keyOver, 3);
        harness.joinPool(keyOver, 4);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: keyExact,
            makerPositionId: makerTokenIdExact,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 701,
            profile: address(0),
            profileParams: bytes32(0)
        });

        MamTypes.CurveDescriptor memory overDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyOver,
            makerPositionId: makerTokenIdOver,
            poolIdA: 3,
            poolIdB: 4,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 702,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.startPrank(maker);
        uint256 exactCurveId = harness.createCurve(desc);
        uint256 overCurveId = harness.createCurve(overDesc);
        vm.stopPrank();

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(exactCurveId, amountIn);
        uint256 overCapQuote = totalQuote + extraQuote;
        tokenB.mint(taker, totalQuote + overCapQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote + overCapQuote);

        uint256 exactMakerQuoteBefore = harness.getUserPrincipal(2, keyExact);
        uint256 exactTrackedBefore = harness.getTrackedBalance(2);
        uint256 exactDepositsBefore = harness.getTotalDeposits(2);
        uint256 exactTakerQuoteBefore = tokenB.balanceOf(taker);
        uint256 exactOut =
            harness.executeCurveSwap(exactCurveId, amountIn, totalQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        uint256 exactTakerSpent = exactTakerQuoteBefore - tokenB.balanceOf(taker);

        uint256 overMakerQuoteBefore = harness.getUserPrincipal(4, keyOver);
        uint256 overTrackedBefore = harness.getTrackedBalance(4);
        uint256 overDepositsBefore = harness.getTotalDeposits(4);
        uint256 overTakerQuoteBefore = tokenB.balanceOf(taker);
        uint256 overOut =
            harness.executeCurveSwap(overCurveId, amountIn, overCapQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        uint256 overTakerSpent = overTakerQuoteBefore - tokenB.balanceOf(taker);
        vm.stopPrank();

        uint256 exactMakerQuoteDelta = harness.getUserPrincipal(2, keyExact) - exactMakerQuoteBefore;
        uint256 overMakerQuoteDelta = harness.getUserPrincipal(4, keyOver) - overMakerQuoteBefore;
        uint256 exactTrackedDelta = harness.getTrackedBalance(2) - exactTrackedBefore;
        uint256 overTrackedDelta = harness.getTrackedBalance(4) - overTrackedBefore;
        uint256 exactDepositsDelta = harness.getTotalDeposits(2) - exactDepositsBefore;
        uint256 overDepositsDelta = harness.getTotalDeposits(4) - overDepositsBefore;

        assertEq(overOut, exactOut, "amount out invariant");
        assertEq(overMakerQuoteDelta, exactMakerQuoteDelta, "maker debt invariant");
        assertEq(overDepositsDelta, exactDepositsDelta, "pool debt invariant");
        assertEq(overTrackedDelta, exactTrackedDelta, "tracked accounting invariant");
        assertEq(exactTakerSpent, totalQuote, "exact path spend");
        assertEq(overTakerSpent, totalQuote, "over-cap should be refunded to net quote");
    }

    function testFuzz_msgValuePolicyEnforcement_nativeQuote(uint256 amountIn, uint256 wrongMsgValue) public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 708,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        amountIn = bound(amountIn, 2, 2e18);
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        wrongMsgValue = bound(wrongMsgValue, 0, (totalQuote * 2) + 1);
        vm.assume(wrongMsgValue != totalQuote);

        vm.deal(taker, wrongMsgValue);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("UnexpectedMsgValue(uint256)", wrongMsgValue));
        harness.executeCurveSwap{value: wrongMsgValue}(
            curveId,
            amountIn,
            totalQuote,
            0,
            uint64(block.timestamp + 1 days),
            taker
        );
    }

    function testFuzz_msgValuePolicyEnforcement_erc20Quote(uint256 amountIn, uint256 wrongMsgValue) public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
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
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 709,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        amountIn = bound(amountIn, 2, 2e18);
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        wrongMsgValue = bound(wrongMsgValue, 1, 10e18);

        tokenB.mint(taker, totalQuote);
        vm.deal(taker, wrongMsgValue);
        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        vm.expectRevert(abi.encodeWithSignature("UnexpectedMsgValue(uint256)", wrongMsgValue));
        harness.executeCurveSwap{value: wrongMsgValue}(
            curveId,
            amountIn,
            totalQuote,
            0,
            uint64(block.timestamp + 1 days),
            taker
        );
        vm.stopPrank();
    }

    function test_nativeQuoteSwap_happyPath() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 710,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);

        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 trackedQuoteBefore = harness.getTrackedBalance(2);
        uint256 nativeBefore = harness.getNativeTrackedTotal();
        uint256 treasuryNativeBefore = treasury.balance;

        vm.deal(taker, totalQuote);
        vm.prank(taker);
        uint256 out =
            harness.executeCurveSwap{value: totalQuote}(curveId, amountIn, totalQuote, 1e18, uint64(block.timestamp + 1 days), taker);

        uint256 feeAmount = totalQuote - amountIn;
        uint256 makerFee = (feeAmount * harness.getMakerShareBps()) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint256 treasuryFee = harness.getTreasuryAddress() != address(0)
            ? (protocolFee * harness.getTreasurySplitBps()) / 10_000
            : 0;

        assertEq(out, 1e18);
        assertEq(tokenA.balanceOf(taker), 1e18);
        assertEq(harness.getUserPrincipal(1, positionKey), makerBaseBefore - 1e18);
        assertEq(harness.getUserPrincipal(2, positionKey), makerQuoteBefore + amountIn + makerFee);
        assertEq(harness.getTrackedBalance(2), trackedQuoteBefore + totalQuote - treasuryFee);
        assertEq(harness.getNativeTrackedTotal(), nativeBefore + totalQuote - treasuryFee);
        assertEq(treasury.balance - treasuryNativeBefore, treasuryFee);
    }

    function testFuzz_nativeQuoteOverCapInvariant(uint256 amountIn, uint256 extraQuote) public {
        amountIn = bound(amountIn, 2, 2e18);
        extraQuote = bound(extraQuote, 1, 10e18);

        uint256 makerTokenIdExact = nft.mint(maker, 1);
        bytes32 keyExact = nft.getPositionKey(makerTokenIdExact);
        uint256 makerTokenIdOver = nft.mint(maker, 1);
        bytes32 keyOver = nft.getPositionKey(makerTokenIdOver);

        harness.seedPool(1, address(tokenA), keyExact, 10e18, 10e18);
        harness.seedPool(2, address(0), keyExact, 0, 0);
        harness.seedPool(3, address(tokenA), keyOver, 10e18, 10e18);
        harness.seedPool(4, address(0), keyOver, 0, 0);
        harness.joinPool(keyExact, 1);
        harness.joinPool(keyExact, 2);
        harness.joinPool(keyOver, 3);
        harness.joinPool(keyOver, 4);

        MamTypes.CurveDescriptor memory exactDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyExact,
            makerPositionId: makerTokenIdExact,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 711,
            profile: address(0),
            profileParams: bytes32(0)
        });
        MamTypes.CurveDescriptor memory overDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyOver,
            makerPositionId: makerTokenIdOver,
            poolIdA: 3,
            poolIdB: 4,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 712,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.startPrank(maker);
        uint256 exactCurveId = harness.createCurve(exactDesc);
        uint256 overCurveId = harness.createCurve(overDesc);
        vm.stopPrank();

        uint256 totalQuote = harness.previewCurveQuote(exactCurveId, amountIn);
        uint256 overCapQuote = totalQuote + extraQuote;
        vm.deal(taker, totalQuote + overCapQuote);

        uint256 exactMakerQuoteBefore = harness.getUserPrincipal(2, keyExact);
        uint256 exactTrackedBefore = harness.getTrackedBalance(2);
        uint256 exactNativeBefore = harness.getNativeTrackedTotal();
        vm.prank(taker);
        uint256 exactOut =
            harness.executeCurveSwap{value: totalQuote}(exactCurveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), taker);
        uint256 exactMakerQuoteDelta = harness.getUserPrincipal(2, keyExact) - exactMakerQuoteBefore;
        uint256 exactTrackedDelta = harness.getTrackedBalance(2) - exactTrackedBefore;
        uint256 exactNativeDelta = harness.getNativeTrackedTotal() - exactNativeBefore;

        uint256 overMakerQuoteBefore = harness.getUserPrincipal(4, keyOver);
        uint256 overTrackedBefore = harness.getTrackedBalance(4);
        uint256 overNativeBefore = harness.getNativeTrackedTotal();
        vm.prank(taker);
        uint256 overOut =
            harness.executeCurveSwap{value: overCapQuote}(overCurveId, amountIn, overCapQuote, 0, uint64(block.timestamp + 1 days), taker);
        uint256 overMakerQuoteDelta = harness.getUserPrincipal(4, keyOver) - overMakerQuoteBefore;
        uint256 overTrackedDelta = harness.getTrackedBalance(4) - overTrackedBefore;
        uint256 overNativeDelta = harness.getNativeTrackedTotal() - overNativeBefore;

        assertEq(overOut, exactOut, "amount out invariant");
        assertEq(overMakerQuoteDelta, exactMakerQuoteDelta, "maker debt invariant");
        assertEq(overTrackedDelta, exactTrackedDelta, "quote tracked invariant");
        assertEq(overNativeDelta, exactNativeDelta, "native tracked invariant");
    }

    function testFuzz_nativeQuoteRefundCorrectness(uint256 amountIn, uint256 extraQuote) public {
        amountIn = bound(amountIn, 2, 2e18);
        extraQuote = bound(extraQuote, 1, 10e18);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 713,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 overCapQuote = totalQuote + extraQuote;
        vm.deal(taker, overCapQuote);

        uint256 takerEthBefore = taker.balance;
        vm.prank(taker);
        uint256 out =
            harness.executeCurveSwap{value: overCapQuote}(curveId, amountIn, overCapQuote, 0, uint64(block.timestamp + 1 days), taker);
        uint256 takerEthSpent = takerEthBefore - taker.balance;

        assertEq(out, amountIn / 2);
        assertEq(takerEthSpent, totalQuote);
    }

    function test_nativeQuoteRefundFailure_revertsWhenCallerRejectsEth() public {
        ETHRejector rejector = new ETHRejector();

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 714,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 overCapQuote = totalQuote + 1e18;
        uint256 refundAmount = overCapQuote - totalQuote;
        vm.deal(address(rejector), overCapQuote);

        vm.expectRevert(abi.encodeWithSignature("NativeTransferFailed(address,uint256)", address(rejector), refundAmount));
        rejector.executeSwap{value: overCapQuote}(
            harness,
            curveId,
            amountIn,
            overCapQuote,
            0,
            uint64(block.timestamp + 1 days),
            maker
        );
    }

    function test_nativeBaseSwap_happyPath() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        vm.deal(address(harness), 3e18);
        harness.seedPool(1, address(0), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 715,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 feeAmount = totalQuote - amountIn;
        uint256 makerFee = (feeAmount * harness.getMakerShareBps()) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint256 treasuryFee = harness.getTreasuryAddress() != address(0)
            ? (protocolFee * harness.getTreasurySplitBps()) / 10_000
            : 0;

        tokenB.mint(taker, totalQuote);
        uint256 recipientNativeBefore = taker.balance;
        uint256 nativeBefore = harness.getNativeTrackedTotal();
        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 trackedQuoteBefore = harness.getTrackedBalance(2);
        uint256 trackedBaseBefore = harness.getTrackedBalance(1);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        uint256 out =
            harness.executeCurveSwap(curveId, amountIn, totalQuote, 1e18, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

        assertEq(out, 1e18);
        assertEq(taker.balance - recipientNativeBefore, 1e18);
        assertEq(harness.getUserPrincipal(1, positionKey), makerBaseBefore - 1e18);
        assertEq(harness.getUserPrincipal(2, positionKey), makerQuoteBefore + amountIn + makerFee);
        assertEq(harness.getTrackedBalance(2), trackedQuoteBefore + totalQuote - treasuryFee);
        assertEq(harness.getTrackedBalance(1), trackedBaseBefore - 1e18);
        assertEq(harness.getNativeTrackedTotal(), nativeBefore - 1e18);
    }

    function testFuzz_nativeBasePayoutDelivery(uint256 amountIn) public {
        amountIn = bound(amountIn, 2, 2e18);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        vm.deal(address(harness), 3e18);
        harness.seedPool(1, address(0), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 716,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, totalQuote);

        uint256 recipientNativeBefore = taker.balance;
        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        uint256 out = harness.executeCurveSwap(curveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

        assertEq(taker.balance - recipientNativeBefore, out);
        assertGt(out, 0);
    }

    function test_nativeBasePayout_revertsWhenRecipientRejectsEth() public {
        ETHRejector rejector = new ETHRejector();
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        vm.deal(address(harness), 3e18);
        harness.seedPool(1, address(0), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 717,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, totalQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        vm.expectRevert(abi.encodeWithSignature("NativeTransferFailed(address,uint256)", address(rejector), 1e18));
        harness.executeCurveSwap(curveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), address(rejector));
        vm.stopPrank();
    }

    function test_nativeBaseSwap_revertsWhenMinOutTooHigh() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        vm.deal(address(harness), 3e18);
        harness.seedPool(1, address(0), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 718,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 expectedOut = amountIn / 2;
        uint256 minOut = expectedOut + 1;
        tokenB.mint(taker, totalQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        vm.expectRevert(abi.encodeWithSignature("MamCurve_Slippage(uint256,uint256)", minOut, expectedOut));
        harness.executeCurveSwap(curveId, amountIn, totalQuote, minOut, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();
    }

    function testFuzz_nativeQuoteSwapAccountingDeltas(uint256 amountIn) public {
        amountIn = bound(amountIn, 2, 2e18);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(0), positionKey, 0, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 719,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 feeAmount = totalQuote - amountIn;
        uint256 makerFee = (feeAmount * harness.getMakerShareBps()) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint256 treasuryFee = harness.getTreasuryAddress() != address(0)
            ? (protocolFee * harness.getTreasurySplitBps()) / 10_000
            : 0;

        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 baseTrackedBefore = harness.getTrackedBalance(1);
        uint256 quoteTrackedBefore = harness.getTrackedBalance(2);
        uint256 nativeBefore = harness.getNativeTrackedTotal();

        vm.deal(taker, totalQuote);
        vm.prank(taker);
        uint256 out =
            harness.executeCurveSwap{value: totalQuote}(curveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), taker);

        assertEq(harness.getUserPrincipal(1, positionKey), makerBaseBefore - out);
        assertEq(harness.getUserPrincipal(2, positionKey), makerQuoteBefore + amountIn + makerFee);
        assertEq(harness.getTrackedBalance(1), baseTrackedBefore - out);
        assertEq(harness.getTrackedBalance(2), quoteTrackedBefore + totalQuote - treasuryFee);
        assertEq(harness.getNativeTrackedTotal(), nativeBefore + totalQuote - treasuryFee);
    }

    function testFuzz_nativeBaseSwapAccountingDeltas(uint256 amountIn) public {
        amountIn = bound(amountIn, 2, 2e18);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        vm.deal(address(harness), 3e18);
        harness.seedPool(1, address(0), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(0),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 720,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 totalQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 feeAmount = totalQuote - amountIn;
        uint256 makerFee = (feeAmount * harness.getMakerShareBps()) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint256 treasuryFee = harness.getTreasuryAddress() != address(0)
            ? (protocolFee * harness.getTreasurySplitBps()) / 10_000
            : 0;

        uint256 makerBaseBefore = harness.getUserPrincipal(1, positionKey);
        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 baseTrackedBefore = harness.getTrackedBalance(1);
        uint256 quoteTrackedBefore = harness.getTrackedBalance(2);
        uint256 nativeBefore = harness.getNativeTrackedTotal();

        tokenB.mint(taker, totalQuote);
        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote);
        uint256 out = harness.executeCurveSwap(curveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

        assertEq(harness.getUserPrincipal(1, positionKey), makerBaseBefore - out);
        assertEq(harness.getUserPrincipal(2, positionKey), makerQuoteBefore + amountIn + makerFee);
        assertEq(harness.getTrackedBalance(1), baseTrackedBefore - out);
        assertEq(harness.getTrackedBalance(2), quoteTrackedBefore + totalQuote - treasuryFee);
        assertEq(harness.getNativeTrackedTotal(), nativeBefore - out);
    }

    function testFuzz_amountOutTokenTypeIndependence(uint256 amountIn) public {
        amountIn = bound(amountIn, 2, 2e18);

        uint256 makerTokenIdErc = nft.mint(maker, 1);
        bytes32 keyErc = nft.getPositionKey(makerTokenIdErc);
        uint256 makerTokenIdNative = nft.mint(maker, 1);
        bytes32 keyNative = nft.getPositionKey(makerTokenIdNative);

        harness.seedPool(1, address(tokenA), keyErc, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), keyErc, 10e18, 10e18);
        harness.seedPool(3, address(tokenA), keyNative, 10e18, 10e18);
        harness.seedPool(4, address(0), keyNative, 0, 0);
        harness.joinPool(keyErc, 1);
        harness.joinPool(keyErc, 2);
        harness.joinPool(keyNative, 3);
        harness.joinPool(keyNative, 4);

        MamTypes.CurveDescriptor memory ercDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyErc,
            makerPositionId: makerTokenIdErc,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 721,
            profile: address(0),
            profileParams: bytes32(0)
        });
        MamTypes.CurveDescriptor memory nativeDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyNative,
            makerPositionId: makerTokenIdNative,
            poolIdA: 3,
            poolIdB: 4,
            tokenA: address(tokenA),
            tokenB: address(0),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 722,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.startPrank(maker);
        uint256 ercCurveId = harness.createCurve(ercDesc);
        uint256 nativeCurveId = harness.createCurve(nativeDesc);
        vm.stopPrank();

        uint256 ercTotalQuote = harness.previewCurveQuote(ercCurveId, amountIn);
        uint256 nativeTotalQuote = harness.previewCurveQuote(nativeCurveId, amountIn);

        tokenB.mint(taker, ercTotalQuote);
        vm.deal(taker, nativeTotalQuote);
        vm.startPrank(taker);
        tokenB.approve(address(harness), ercTotalQuote);
        uint256 ercOut = harness.executeCurveSwap(ercCurveId, amountIn, ercTotalQuote, 0, uint64(block.timestamp + 1 days), taker);
        uint256 nativeOut = harness.executeCurveSwap{value: nativeTotalQuote}(
            nativeCurveId,
            amountIn,
            nativeTotalQuote,
            0,
            uint64(block.timestamp + 1 days),
            taker
        );
        vm.stopPrank();

        assertEq(nativeOut, ercOut);
    }

    function testFuzz_curveFilledActualInSemantics(uint256 amountIn, uint256 extraQuote) public {
        amountIn = bound(amountIn, 2, 2e18);
        extraQuote = bound(extraQuote, 1, 10e18);

        uint256 makerTokenIdExact = nft.mint(maker, 1);
        bytes32 keyExact = nft.getPositionKey(makerTokenIdExact);
        uint256 makerTokenIdOver = nft.mint(maker, 1);
        bytes32 keyOver = nft.getPositionKey(makerTokenIdOver);

        harness.seedPool(1, address(tokenA), keyExact, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), keyExact, 10e18, 10e18);
        harness.seedPool(3, address(tokenA), keyOver, 10e18, 10e18);
        harness.seedPool(4, address(tokenB), keyOver, 10e18, 10e18);
        harness.joinPool(keyExact, 1);
        harness.joinPool(keyExact, 2);
        harness.joinPool(keyOver, 3);
        harness.joinPool(keyOver, 4);

        MamTypes.CurveDescriptor memory exactDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyExact,
            makerPositionId: makerTokenIdExact,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 723,
            profile: address(0),
            profileParams: bytes32(0)
        });
        MamTypes.CurveDescriptor memory overDesc = MamTypes.CurveDescriptor({
            makerPositionKey: keyOver,
            makerPositionId: makerTokenIdOver,
            poolIdA: 3,
            poolIdB: 4,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 724,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.startPrank(maker);
        uint256 exactCurveId = harness.createCurve(exactDesc);
        uint256 overCurveId = harness.createCurve(overDesc);
        vm.stopPrank();

        uint256 totalQuote = harness.previewCurveQuote(exactCurveId, amountIn);
        uint256 overCapQuote = totalQuote + extraQuote;
        uint256 expectedOut = amountIn / 2;
        uint256 feeAmount = totalQuote - amountIn;
        uint256 expectedRemaining = 2e18 - expectedOut;
        tokenB.mint(taker, totalQuote + overCapQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), totalQuote + overCapQuote);

        vm.expectEmit(true, true, true, true, address(harness));
        emit CurveFilled(exactCurveId, taker, taker, amountIn, totalQuote, expectedOut, feeAmount, expectedRemaining);
        harness.executeCurveSwap(exactCurveId, amountIn, totalQuote, 0, uint64(block.timestamp + 1 days), taker);

        vm.expectEmit(true, true, true, true, address(harness));
        emit CurveFilled(overCurveId, taker, taker, amountIn, totalQuote, expectedOut, feeAmount, expectedRemaining);
        harness.executeCurveSwap(overCurveId, amountIn, overCapQuote, 0, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();
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
            salt: 2,
            profile: address(0),
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 20),
            duration: 2 days,
            updateProfile: false,
            profile: address(0),
            updateProfileParams: false,
            profileParams: bytes32(0)
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
            salt: 3,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 11,
            profile: address(0),
            profileParams: bytes32(0)
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
            duration: 2 days,
            updateProfile: false,
            profile: address(0),
            updateProfileParams: false,
            profileParams: bytes32(0)
        });
        params[1] = MamTypes.CurveUpdateParams({
            startPrice: 4e18,
            endPrice: 3e18,
            startTime: uint64(block.timestamp + 30),
            duration: 3 days,
            updateProfile: false,
            profile: address(0),
            updateProfileParams: false,
            profileParams: bytes32(0)
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
            salt: 21,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 3,
            profile: address(0),
            profileParams: bytes32(0)
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
            salt: 11,
            profile: address(0),
            profileParams: bytes32(0)
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

    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function pointsBalance(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function pointsBalanceForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.balanceOf(pointsKey);
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
            if (underlying == address(0)) {
                LibAppStorage.s().nativeTrackedTotal += tracked;
            } else {
                MockERC20(underlying).mint(address(this), tracked);
            }
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

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getNativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function getStoredCurve(uint256 curveId) external view returns (MamTypes.StoredCurve memory) {
        return LibDerivativeStorage.derivativeStorage().curves[curveId];
    }
}

contract ETHRejector {
    function executeSwap(
        MamCurveHarness harness,
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient
    ) external payable returns (uint256) {
        return harness.executeCurveSwap{value: msg.value}(curveId, amountIn, maxQuote, minOut, deadline, recipient);
    }
}

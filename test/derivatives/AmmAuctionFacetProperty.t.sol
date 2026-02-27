// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    AmmAuctionFacet,
    AmmAuction_NotActive
} from "../../src/EqualX/AmmAuctionFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Feature: position-nft-derivatives, Property 1: AMM invariant preservation
/// @notice Validates: Requirements 4.1, 12.1
/// forge-config: default.fuzz.runs = 100
contract AmmAuctionFacetPropertyTest is Test {
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

    AmmAuctionHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal treasury = address(0xC0FFEE);

    function setUp() public {
        harness = new AmmAuctionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);
    }

    function test_CreateAuctionPersistsInvariantModeAndEmitsEvent() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 3e18, 3e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Stable
        });

        vm.expectEmit(true, true, true, true, address(harness));
        emit AuctionCreated(
            1,
            positionKey,
            makerTokenId,
            1,
            2,
            address(tokenA),
            address(tokenB),
            1e18,
            1e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            0,
            DerivativeTypes.FeeAsset.TokenIn,
            DerivativeTypes.InvariantMode.Stable
        );

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        assertEq(uint8(auction.invariantMode), uint8(DerivativeTypes.InvariantMode.Stable), "mode persisted");
    }

    function test_StableMode_PreviewSwapMatchesExecution() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6, 0);
        MockERC20 dai = new MockERC20("DAI", "DAI", 18, 0);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveUsdc = 1_000_000e6;
        uint256 reserveDai = 1_000_000e18;
        harness.seedPool(1, address(usdc), positionKey, reserveUsdc + 100e6, reserveUsdc + 100e6);
        harness.seedPool(2, address(dai), positionKey, reserveDai + 100e18, reserveDai + 100e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveUsdc,
                reserveB: reserveDai,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Stable
            })
        );

        uint256 amountIn = 50e6;
        (uint256 previewOut, uint256 previewFee) = harness.previewSwap(auctionId, address(usdc), amountIn);
        assertGt(previewOut, 0, "stable preview out");
        assertEq(previewFee, Math.mulDiv(amountIn, 30, 10_000), "stable preview fee");

        usdc.mint(taker, amountIn);
        vm.prank(taker);
        usdc.approve(address(harness), amountIn);

        vm.prank(taker);
        (uint256 amountOut,) = harness.swapExactInOrFinalize(auctionId, address(usdc), amountIn, amountIn, previewOut, taker);

        assertEq(amountOut, previewOut, "stable preview/execution parity");
    }

    function test_VolatileMode_PreviewMatchesLegacyMathSnapshot() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 50e18;
        uint256 reserveB = 100e18;
        harness.seedPool(1, address(tokenA), positionKey, reserveA + 10e18, reserveA + 10e18);
        harness.seedPool(2, address(tokenB), positionKey, reserveB + 10e18, reserveB + 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 25,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 amountIn = 10e18;
        uint256 amountInWithFee = Math.mulDiv(amountIn, 10_000 - 25, 10_000);
        uint256 expectedFee = amountIn - amountInWithFee;
        uint256 expectedOut = Math.mulDiv(reserveB, amountInWithFee, reserveA + amountInWithFee);

        (uint256 previewOut, uint256 previewFee) = harness.previewSwap(auctionId, address(tokenA), amountIn);
        assertEq(previewOut, expectedOut, "volatile output snapshot");
        assertEq(previewFee, expectedFee, "volatile fee snapshot");

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        (uint256 amountOut,) = harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, expectedOut, taker);
        assertEq(amountOut, expectedOut, "volatile preview/execution parity");
    }

    function testProperty_InvariantPreservation(
        uint96 reserveA,
        uint96 reserveB,
        uint96 amountIn,
        uint16 feeBps
    ) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountIn = uint96(bound(amountIn, 1, reserveA));
        feeBps = uint16(bound(feeBps, 0, 1_000));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = uint256(reserveA) + 1e6;
        uint256 principalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: feeBps,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        uint256 kBefore = Math.mulDiv(reserveA, reserveB, 1);

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, 0, taker);

        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        uint256 kAfter = Math.mulDiv(auction.reserveA, auction.reserveB, 1);
        assertGe(kAfter, kBefore, "invariant preserved or increased");
    }

    function test_AmmSwapAccruesPointsToSwapper() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        uint256 takerTokenId = nft.mint(taker, 1);
        bytes32 takerKey = nft.getPositionKey(takerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 3e18, 3e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
        harness.setPointsPerAction(LibPoints.ACTION_SWAP_AMM_AUCTION, 9);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 1e18,
                reserveB: 1e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        tokenA.mint(taker, 1e18);
        vm.prank(taker);
        tokenA.approve(address(harness), 1e18);

        assertEq(harness.pointsBalance(taker), 0);
        assertEq(harness.pointsBalanceForKey(takerKey), 0);
        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), 1e18, 1e18, 0, taker);
        assertEq(harness.pointsBalance(taker), 0);
        assertEq(harness.pointsBalanceForKey(takerKey), 9);
    }

    /// @notice Property: swap time window enforcement
    /// @notice Validates: Requirements 4.4
    function testProperty_TimeWindowEnforcement() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 1e18, 1e18);
        harness.seedPool(2, address(tokenB), positionKey, 1e18, 1e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 startTime = uint64(block.timestamp + 100);
        uint64 endTime = startTime + 1000;

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: startTime,
            endTime: endTime,
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        tokenA.mint(taker, 1e18);
        vm.prank(taker);
        tokenA.approve(address(harness), 1e18);

        vm.warp(startTime - 1);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(AmmAuction_NotActive.selector, auctionId));
        harness.swapExactInOrFinalize(auctionId, address(tokenA), 1e18, 1e18, 0, taker);

        vm.warp(endTime);
        vm.prank(taker);
        (uint256 amountOut, bool finalized) =
            harness.swapExactInOrFinalize(auctionId, address(tokenA), 1e18, 1e18, 0, taker);
        assertEq(amountOut, 0, "no swap output after expiry");
        assertTrue(finalized, "expiry path finalizes auction");
    }

    /// @notice Property: flash accounting isolation
    /// @notice Validates: Requirements 4.7
    function testProperty_FlashAccountingIsolation() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 2e18, 2e18);
        harness.seedPool(2, address(tokenB), positionKey, 2e18, 2e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        uint256 principalA = harness.getUserPrincipal(1, positionKey);
        uint256 principalB = harness.getUserPrincipal(2, positionKey);
        uint256 feeIndexA = harness.getUserFeeIndex(1, positionKey);
        uint256 feeIndexB = harness.getUserFeeIndex(2, positionKey);

        tokenA.mint(taker, 1e18);
        vm.prank(taker);
        tokenA.approve(address(harness), 1e18);

        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), 1e18, 1e18, 0, taker);

        uint256 principalAfterA = harness.getUserPrincipal(1, positionKey);
        uint256 principalAfterB = harness.getUserPrincipal(2, positionKey);
        uint256 totalDepositsA = harness.getTotalDeposits(1);
        uint256 totalDepositsB = harness.getTotalDeposits(2);

        assertEq(principalAfterA, principalA, "principal A unchanged during swaps");
        assertEq(principalAfterB, principalB, "principal B unchanged during swaps");
        assertEq(totalDepositsA, principalA, "totalDeposits A unchanged during swaps");
        assertEq(totalDepositsB, principalB, "totalDeposits B unchanged during swaps");
        assertEq(harness.getUserFeeIndex(1, positionKey), feeIndexA, "fee index A unchanged during swaps");
        assertEq(harness.getUserFeeIndex(2, positionKey), feeIndexB, "fee index B unchanged during swaps");
    }

    /// @notice Property: fee accrual correctness
    /// @notice Validates: Requirements 4.3
    function testProperty_FeeAccrualCorrectness() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 2e18, 2e18);
        harness.seedPool(2, address(tokenB), positionKey, 2e18, 2e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 100,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        uint256 amountIn = 1e18;
        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        uint256 feeIndexBefore = harness.getFeeIndex(1);

        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, 0, taker);

        uint256 totalDeposits = harness.getTotalDeposits(1);
        (uint256 makerFeeA, uint256 makerFeeB) = harness.getAuctionFees(auctionId);
        uint256 totalFee = (amountIn * params.feeBps) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 expectedMaker = (totalFee * makerShareBps) / 10_000;
        uint256 protocolFee = totalFee - expectedMaker;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        uint16 activeBps = harness.getActiveCreditSplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 expectedTreasury = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;
        uint256 expectedActive = (protocolFee * activeBps) / 10_000;
        uint256 expectedIndex = protocolFee - expectedTreasury - expectedActive;
        uint256 expectedIndexDelta = (expectedIndex * 1e18) / totalDeposits;
        uint256 feeIndexAfter = harness.getFeeIndex(1);

        assertEq(makerFeeA, expectedMaker, "maker fee accrued");
        assertEq(makerFeeB, 0, "no fee in B");
        assertEq(tokenA.balanceOf(treasury), expectedTreasury, "treasury fee transferred");
        assertEq(feeIndexAfter, feeIndexBefore + expectedIndexDelta, "fee index accrues");
    }

    function test_AmmSwapKeepsIndexFeeInReserves() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 3 ether;
        uint256 reserveB = 9000 ether;
        uint256 amountIn = 1 ether;
        uint16 feeBps = 100;

        uint256 principalA = reserveA + 10 ether;
        uint256 principalB = reserveB + 10 ether;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: feeBps,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, 0, taker);

        uint256 feeAmount = (amountIn * feeBps) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 expectedTreasury = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;
        uint256 expectedReserveA = reserveA + amountIn - expectedTreasury;

        DerivativeTypes.AmmAuction memory auctionAfter = harness.getAuction(auctionId);
        assertEq(auctionAfter.reserveA, expectedReserveA, "reserve should retain index fee");
    }

    /// @notice Unit test: AMM reserves tracked as directLentPrincipal keep fee index accrual
    /// @notice Validates: Requirements 2.4
    function test_AmmFeeIndexAccrual() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10 ether;
        uint256 feeAmount = 1 ether;
        harness.seedPool(1, address(tokenA), positionKey, principal, principal + feeAmount);
        harness.joinPool(positionKey, 1);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1 ether,
            reserveB: 1 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        harness.seedPool(2, address(tokenB), positionKey, 2 ether, 2 ether);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        harness.createAuction(params);

        harness.accrueFeeIndex(1, feeAmount, bytes32("AMM_TEST"));

        uint256 pending = harness.pendingYield(1, positionKey);
        assertEq(pending, feeAmount, "fee index accrues on principal despite encumbrance");
    }

    function test_AmmAuctionCancelAdjustsTotalDeposits() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 2 ether;
        uint256 reserveB = 4 ether;
        uint256 amountIn = 1 ether;

        uint256 principalA = reserveA + 5 ether;
        uint256 principalB = reserveB + 5 ether;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        harness.swapExactInOrFinalize(auctionId, address(tokenA), amountIn, amountIn, 0, taker);

        DerivativeTypes.AmmAuction memory auctionAfter = harness.getAuction(auctionId);
        uint256 deltaA = auctionAfter.reserveA - reserveA;
        uint256 deltaB = reserveB - auctionAfter.reserveB;

        // Principals remain flash-accounted until settlement
        assertEq(harness.getUserPrincipal(1, positionKey), principalA, "principal A unchanged mid-auction");
        assertEq(harness.getTotalDeposits(1), principalA, "totalDeposits A unchanged mid-auction");
        assertEq(harness.getUserPrincipal(2, positionKey), principalB, "principal B unchanged mid-auction");
        assertEq(harness.getTotalDeposits(2), principalB, "totalDeposits B unchanged mid-auction");

        vm.prank(maker);
        harness.cancelAuction(auctionId);

        // Settlement applies the deltas once
        assertEq(harness.getUserPrincipal(1, positionKey), principalA + deltaA, "principal A settled");
        assertEq(harness.getTotalDeposits(1), principalA + deltaA, "totalDeposits A settled");
        assertEq(harness.getUserPrincipal(2, positionKey), principalB - deltaB, "principal B settled");
        assertEq(harness.getTotalDeposits(2), principalB - deltaB, "totalDeposits B settled");
    }

    function test_AmmSwapUsesActualInForFeeOnTransfer() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("FeeToken", "FEE", 18, 0, 500, address(0xFEE));
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18, 0);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 2e18;
        uint256 reserveB = 4e18;
        harness.seedPool(1, address(feeToken), positionKey, reserveA + 1e18, reserveA + 1e18);
        harness.seedPool(2, address(otherToken), positionKey, reserveB + 1e18, reserveB + 1e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 amountIn = 1e18;
        uint256 grossIn = Math.mulDiv(amountIn, 10_000, 10_000 - 500, Math.Rounding.Ceil);
        feeToken.mint(taker, grossIn);
        vm.prank(taker);
        feeToken.approve(address(harness), grossIn);

        uint256 trackedBefore = harness.getTrackedBalance(1);
        uint256 expectedReceived = grossIn - ((grossIn * 500) / 10_000);
        uint256 expectedOut = Math.mulDiv(reserveB, expectedReceived, reserveA + expectedReceived);

        vm.prank(taker);
        (uint256 amountOut,) =
            harness.swapExactInOrFinalize(auctionId, address(feeToken), amountIn, grossIn, 0, taker);

        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        assertEq(auction.reserveA, reserveA + expectedReceived, "reserve A uses actual received");
        assertEq(auction.reserveB, reserveB - expectedOut, "reserve B uses actual received");
        assertEq(harness.getTrackedBalance(1), trackedBefore, "tracked balance untouched during swap");
        assertEq(amountOut, expectedOut, "amount out uses actual received");
    }

    function test_AddLiquidityUpdatesReservesAndEncumbrance() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 5 ether;
        uint256 reserveB = 10 ether;
        uint256 addA = 1 ether;
        uint256 addB = 2 ether;

        uint256 principalA = reserveA + addA + 5 ether;
        uint256 principalB = reserveB + addB + 5 ether;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 lentBeforeA = harness.getDirectLent(positionKey, 1);
        uint256 lentBeforeB = harness.getDirectLent(positionKey, 2);

        vm.prank(maker);
        harness.addLiquidity(auctionId, addA, addB);

        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        assertEq(auction.reserveA, reserveA + addA, "reserve A increased");
        assertEq(auction.reserveB, reserveB + addB, "reserve B increased");
        assertEq(auction.initialReserveA, reserveA + addA, "initial reserve A updated");
        assertEq(auction.initialReserveB, reserveB + addB, "initial reserve B updated");
        assertEq(auction.invariant, Math.mulDiv(reserveA + addA, reserveB + addB, 1), "invariant updated");
        assertEq(harness.getDirectLent(positionKey, 1), lentBeforeA + addA, "direct lent A increased");
        assertEq(harness.getDirectLent(positionKey, 2), lentBeforeB + addB, "direct lent B increased");
    }

    function test_AuctionDiscoveryIndexes() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 1e18, 1e18);
        harness.seedPool(2, address(tokenB), positionKey, 1e18, 1e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + 1 days;
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: startTime,
            endTime: endTime,
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        (uint256[] memory poolIdsA, uint256 poolTotalA) = harness.getAuctionsByPool(1, 0, 10);
        (uint256[] memory poolIdsB, uint256 poolTotalB) = harness.getAuctionsByPool(2, 0, 10);
        (uint256[] memory tokenIdsA, uint256 tokenTotalA) = harness.getAuctionsByToken(address(tokenA), 0, 10);
        (uint256[] memory tokenIdsB, uint256 tokenTotalB) = harness.getAuctionsByToken(address(tokenB), 0, 10);
        (uint256[] memory pairIds, uint256 pairTotal) =
            harness.getAuctionsByPair(address(tokenA), address(tokenB), 0, 10);

        assertEq(poolTotalA, 1, "pool A indexed");
        assertEq(poolIdsA[0], auctionId, "pool A id");
        assertEq(poolTotalB, 1, "pool B indexed");
        assertEq(poolIdsB[0], auctionId, "pool B id");
        assertEq(tokenTotalA, 1, "token A indexed");
        assertEq(tokenIdsA[0], auctionId, "token A id");
        assertEq(tokenTotalB, 1, "token B indexed");
        assertEq(tokenIdsB[0], auctionId, "token B id");
        assertEq(pairTotal, 1, "pair indexed");
        assertEq(pairIds[0], auctionId, "pair id");

        vm.warp(endTime);
        harness.finalizeAuction(auctionId);

        (, poolTotalA) = harness.getAuctionsByPool(1, 0, 10);
        (, poolTotalB) = harness.getAuctionsByPool(2, 0, 10);
        (, tokenTotalA) = harness.getAuctionsByToken(address(tokenA), 0, 10);
        (, tokenTotalB) = harness.getAuctionsByToken(address(tokenB), 0, 10);
        (, pairTotal) = harness.getAuctionsByPair(address(tokenA), address(tokenB), 0, 10);

        assertEq(poolTotalA, 0, "pool A cleared");
        assertEq(poolTotalB, 0, "pool B cleared");
        assertEq(tokenTotalA, 0, "token A cleared");
        assertEq(tokenTotalB, 0, "token B cleared");
        assertEq(pairTotal, 0, "pair cleared");
    }

    function test_AuctionGlobalListAndBestQuote() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), positionKey, 10e18, 10e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + 1 days;
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 2e18,
            startTime: startTime,
            endTime: endTime,
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(maker);
        uint256 auctionId1 = harness.createAuction(params);

        params.reserveB = 3e18;
        vm.prank(maker);
        uint256 auctionId2 = harness.createAuction(params);

        (uint256[] memory activeIds, uint256 totalActive) = harness.getActiveAuctions(0, 10);
        assertEq(totalActive, 2, "global list count");
        assertEq(activeIds[0], auctionId1, "global first");
        assertEq(activeIds[1], auctionId2, "global second");

        (uint256 bestAuctionId, uint256 bestOut,) =
            harness.findBestAuctionExactIn(address(tokenA), address(tokenB), 1e18, 0, 10);
        assertEq(bestAuctionId, auctionId2, "best auction");
        assertGt(bestOut, 0, "best out");

        (uint256 out,, uint256 minOut) =
            harness.previewSwapWithSlippage(auctionId2, address(tokenA), 1e18, 500);
        assertGt(out, 0, "quote out");
        assertEq(minOut, (out * 9500) / 10_000, "min out");

        vm.prank(maker);
        harness.cancelAuction(auctionId1);
        (activeIds, totalActive) = harness.getActiveAuctions(0, 10);
        assertEq(totalActive, 1, "global list after cancel");
        assertEq(activeIds[0], auctionId2, "global remaining");
    }
}

contract AmmAuctionHarness is AmmAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.ammMakerShareBps = shareBps;
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
        return LibDerivativeStorage.derivativeStorage().config.ammMakerShareBps;
    }

    function getTreasurySplitBps() external view returns (uint16) {
        return LibAppStorage.treasurySplitBps(LibAppStorage.s());
    }

    function getActiveCreditSplitBps() external view returns (uint16) {
        return LibAppStorage.activeCreditSplitBps(LibAppStorage.s());
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

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getUserFeeIndex(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userFeeIndex[positionKey];
    }

    function accrueFeeIndex(uint256 pid, uint256 amount, bytes32 source) external {
        LibFeeIndex.accrueWithSource(pid, amount, source);
    }

    function pendingYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, positionKey);
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function getDirectLent(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.get(positionKey, poolId).directLent;
    }

    function getAuctionsByPool(uint256 poolId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByPoolPage(poolId, offset, limit);
    }

    function getAuctionsByToken(address token, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByTokenPage(token, offset, limit);
    }

    function getAuctionsByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByPairPage(tokenA, tokenB, offset, limit);
    }

    function getActiveAuctions(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsGlobalPage(offset, limit);
    }

    function previewSwapWithSlippage(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) external view returns (uint256 amountOut, uint256 feeAmount, uint256 minOut) {
        (amountOut, feeAmount) = this.previewSwap(auctionId, tokenIn, amountIn);
        if (amountOut == 0) {
            return (0, feeAmount, 0);
        }
        if (slippageBps > 10_000) {
            slippageBps = 10_000;
        }
        minOut = (amountOut * (10_000 - slippageBps)) / 10_000;
    }

    function findBestAuctionExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256 bestAuctionId, uint256 bestAmountOut, uint256 checked) {
        (uint256[] memory ids, uint256 total) = LibDerivativeStorage.auctionsByPairPage(
            tokenIn,
            tokenOut,
            offset,
            limit
        );
        total;
        uint256 count = ids.length;
        checked = count;
        for (uint256 i = 0; i < count; i++) {
            uint256 auctionId = ids[i];
            DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
            if (!auction.active || auction.finalized) {
                continue;
            }
            if (block.timestamp < auction.startTime || block.timestamp >= auction.endTime) {
                continue;
            }
            (uint256 out,) = this.previewSwap(auctionId, tokenIn, amountIn);
            if (out > bestAmountOut) {
                bestAmountOut = out;
                bestAuctionId = auctionId;
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Regression test for community auction index fee backing bug.
/// @dev The bug: index fees accrued to pool yieldReserve were not properly backed
/// when makers withdrew from the auction. Makers would withdraw their full share
/// of reserves (including index fee portion), leaving yieldReserve unbacked.
contract CommunityAuctionIndexFeeRegressionTest is Test {
    CommunityAuctionIndexFeeHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal joiner = address(0xB0B);
    address internal taker = address(0xCAFE);
    address internal treasury = address(0xBEEF);

    function setUp() public {
        harness = new CommunityAuctionIndexFeeHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);
    }

    /// @notice Verifies that yieldReserve remains properly backed after makers leave.
    /// This is the core regression test for the index fee backing bug.
    function test_yieldReserveBackedAfterMakersLeave() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 10 ether;
        uint256 reserveB = 10 ether;
        uint256 principalA = reserveA + 5 ether;
        uint256 principalB = reserveB + 5 ether;

        harness.seedPool(1, address(tokenA), makerKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerKey, principalB, principalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100, // 1% fee
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        // Perform swaps to generate index fees
        uint256 swapAmount = 2 ether;
        tokenA.mint(taker, swapAmount);
        vm.startPrank(taker);
        tokenA.approve(address(harness), swapAmount);
        harness.swapExactIn(auctionId, address(tokenA), swapAmount, 0, taker);
        vm.stopPrank();

        // Check index fees were accrued
        DerivativeTypes.CommunityAuction memory auctionAfterSwap = harness.getCommunityAuction(auctionId);
        assertGt(auctionAfterSwap.indexFeeAAccrued, 0, "index fee A should be accrued");

        // Get pool state before maker leaves
        uint256 yieldReserveBefore = harness.yieldReserve(1);
        uint256 trackedBalanceBefore = harness.trackedBalance(1);
        uint256 totalDepositsBefore = harness.totalDeposits(1);

        assertGt(yieldReserveBefore, 0, "yield reserve should be positive after swap");

        // Maker leaves the auction
        vm.prank(maker);
        harness.leaveCommunityAuction(auctionId, makerTokenId);

        // Verify yieldReserve is properly backed
        uint256 yieldReserveAfter = harness.yieldReserve(1);
        uint256 trackedBalanceAfter = harness.trackedBalance(1);
        uint256 totalDepositsAfter = harness.totalDeposits(1);

        // The key invariant: trackedBalance >= totalDeposits + yieldReserve
        assertGe(
            trackedBalanceAfter,
            totalDepositsAfter + yieldReserveAfter,
            "trackedBalance must back totalDeposits + yieldReserve"
        );

        // Verify maker can roll yield without liquidity errors
        vm.prank(maker);
        harness.rollYieldToPosition(makerTokenId, 1);

        // After rolling, yieldReserve should be consumed
        assertLe(harness.yieldReserve(1), 10, "yield reserve should be near zero after roll");
    }

    /// @notice Test with multiple makers to ensure pro-rata index fee handling works.
    function test_multiMakerIndexFeeBacking() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);
        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);

        uint256 reserveA = 10 ether;
        uint256 reserveB = 10 ether;

        // Setup maker
        harness.seedPool(1, address(tokenA), makerKey, reserveA + 5 ether, reserveA + 5 ether);
        harness.seedPool(2, address(tokenB), makerKey, reserveB + 5 ether, reserveB + 5 ether);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        // Setup joiner
        harness.seedPool(1, address(tokenA), joinerKey, reserveA + 5 ether, reserveA + 5 ether);
        harness.seedPool(2, address(tokenB), joinerKey, reserveB + 5 ether, reserveB + 5 ether);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        // Joiner adds equal liquidity
        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, reserveA, reserveB);

        // Perform swaps
        uint256 swapAmount = 4 ether;
        tokenA.mint(taker, swapAmount);
        vm.startPrank(taker);
        tokenA.approve(address(harness), swapAmount);
        harness.swapExactIn(auctionId, address(tokenA), swapAmount, 0, taker);
        vm.stopPrank();

        // First maker leaves
        vm.prank(maker);
        harness.leaveCommunityAuction(auctionId, makerTokenId);

        // Check backing after first leave
        // Note: auction reserves (including index fees) provide additional backing via extraBacking
        DerivativeTypes.CommunityAuction memory auctionAfterFirst = harness.getCommunityAuction(auctionId);
        uint256 auctionBacking = auctionAfterFirst.reserveA; // Index fees stay in auction reserves
        assertGe(
            harness.trackedBalance(1) + auctionBacking,
            harness.totalDeposits(1) + harness.yieldReserve(1),
            "backing after first leave (including auction reserves)"
        );

        // Second maker leaves
        vm.prank(joiner);
        harness.leaveCommunityAuction(auctionId, joinerTokenId);

        // Check backing after all makers leave
        assertGe(
            harness.trackedBalance(1),
            harness.totalDeposits(1) + harness.yieldReserve(1),
            "backing after all leave"
        );
    }

    /// @notice Verify index fees are tracked correctly in the auction struct.
    function test_indexFeeTracking() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 10 ether;
        uint256 reserveB = 10 ether;

        harness.seedPool(1, address(tokenA), makerKey, reserveA + 5 ether, reserveA + 5 ether);
        harness.seedPool(2, address(tokenB), makerKey, reserveB + 5 ether, reserveB + 5 ether);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100, // 1% fee
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        // Initial state - no index fees
        DerivativeTypes.CommunityAuction memory auctionBefore = harness.getCommunityAuction(auctionId);
        assertEq(auctionBefore.indexFeeAAccrued, 0, "initial index fee A");
        assertEq(auctionBefore.indexFeeBAccrued, 0, "initial index fee B");

        // Swap tokenA -> tokenB (fee in tokenA)
        uint256 swapAmount = 1 ether;
        tokenA.mint(taker, swapAmount);
        vm.startPrank(taker);
        tokenA.approve(address(harness), swapAmount);
        harness.swapExactIn(auctionId, address(tokenA), swapAmount, 0, taker);
        vm.stopPrank();

        // Check index fee was tracked
        DerivativeTypes.CommunityAuction memory auctionAfter = harness.getCommunityAuction(auctionId);
        
        uint256 totalFee = (swapAmount * 100) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (totalFee * makerShareBps) / 10_000;
        uint256 protocolFee = totalFee - makerFee;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        uint16 activeBps = harness.getActiveCreditSplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 treasuryShare = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;
        uint256 activeShare = (protocolFee * activeBps) / 10_000;
        uint256 expectedIndexFee = protocolFee - treasuryShare - activeShare;
        assertEq(auctionAfter.indexFeeAAccrued, expectedIndexFee, "index fee A tracked");
        assertEq(auctionAfter.indexFeeBAccrued, 0, "index fee B unchanged");
    }
}

/// @notice Harness combining CommunityAuctionFacet with PositionManagementFacet for testing.
contract CommunityAuctionIndexFeeHarness is CommunityAuctionFacet, PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setTreasury(address _treasury) external {
        LibAppStorage.s().treasury = _treasury;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps = shareBps;
    }

    function getMakerShareBps() external view returns (uint16) {
        return LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps;
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
        p.userPrincipal[positionKey] += principal;
        p.totalDeposits += principal;
        p.trackedBalance += tracked;
        p.poolConfig.minDepositAmount = 1;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function yieldReserve(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }
}

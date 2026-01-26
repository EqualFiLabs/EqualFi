// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Regression harness that wires the AMM auction facet with position management to check yield reserve backing.
contract AmmAuctionYieldReserveHarness is AmmAuctionFacet, PositionManagementFacet {
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
        p.totalDeposits = principal;
        p.userPrincipal[positionKey] = principal;
        p.trackedBalance = tracked;
        p.poolConfig.minDepositAmount = 1; // avoid zero-deposit guardrails
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
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

    // View helpers for assertions
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

contract AmmAuctionYieldReserveRegressionTest is Test {
    AmmAuctionYieldReserveHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    function setUp() public {
        harness = new AmmAuctionYieldReserveHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        harness.setTreasury(address(0xC0FFEE));
        harness.setMakerShareBps(7000);
    }

    /// @notice Reproduces the Base Sepolia AMM trade sequence and checks trackedBalance backing.
    function test_yieldReserveBackedAfterAuctionCancel() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        // Seed pools roughly matching on-chain sizes
        uint256 reserveA = 5 ether; // rETH leg
        uint256 reserveB = 125_299_488_512; // USDC leg (no decimals scaling needed for MockERC20)
        harness.seedPool(1, address(tokenA), positionKey, reserveA + 10 ether, reserveA + 10 ether);
        harness.seedPool(5, address(tokenB), positionKey, reserveB + 25e18, reserveB + 25e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 5);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 5,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30, // 0.3%
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createAuction(params);

        // Swap rETH -> USDC
        tokenA.mint(taker, 1 ether);
        vm.startPrank(taker);
        tokenA.approve(address(harness), 1 ether);
        harness.swapExactIn(auctionId, address(tokenA), 1 ether, 0, taker);

        // Swap USDC -> rETH
        uint256 usdcIn = 3_200 * 1e18;
        tokenB.mint(taker, usdcIn);
        tokenB.approve(address(harness), usdcIn);
        harness.swapExactIn(auctionId, address(tokenB), usdcIn, 0, taker);
        vm.stopPrank();

        DerivativeTypes.AmmAuction memory auctionAfter = harness.getAuction(auctionId);
        uint256 extraBacking = auctionAfter.poolIdA == 5 ? auctionAfter.reserveA : auctionAfter.reserveB;
        // Encumbered reserves back yield during the auction.
        assertGe(
            harness.trackedBalance(5) + extraBacking,
            harness.totalDeposits(5) + harness.yieldReserve(5),
            "tracked after swaps"
        );

        vm.prank(maker);
        harness.cancelAuction(auctionId);

        uint256 deposits = harness.totalDeposits(5);
        uint256 reserve = harness.yieldReserve(5);
        uint256 tracked = harness.trackedBalance(5);

        // The pool should have enough tracked balance to cover principal + yield reserve.
        assertGe(tracked, deposits + reserve, "tracked balance under-reserved");

        // Maker can roll yield without tripping liquidity checks.
        vm.prank(maker);
        harness.rollYieldToPosition(makerTokenId, 5);

        assertLe(harness.yieldReserve(5), 50, "yield reserve dust only");
        assertGe(harness.trackedBalance(5), harness.totalDeposits(5), "tracked covers deposits");
    }
}

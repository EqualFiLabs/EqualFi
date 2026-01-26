// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice Regression test to surface backing leaks across a full community auction lifecycle with two makers.
contract CommunityAuctionLifecycleHarness is CommunityAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function seedPool(uint256 pid, address underlying, bytes32 posKey, uint256 principal, uint256 tracked) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[posKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        p.userFeeIndex[posKey] = p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.userMaintenanceIndex[posKey] = p.maintenanceIndex =
            p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
    }

    function joinPool(bytes32 posKey, uint256 pid) external {
        LibPoolMembership._joinPool(posKey, pid);
    }

    function getBacking(uint256 pid)
        external
        view
        returns (uint256 totalDeposits, uint256 trackedBalance, uint256 yieldReserve)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        yieldReserve = p.yieldReserve;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPoolTotals(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
    }
}

contract CommunityAuctionLifecycleRegressionTest is Test {
    CommunityAuctionLifecycleHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function _logBacking(string memory label) internal {
        (uint256 tdA, uint256 trA, uint256 yrA) = facet.getBacking(PID_A);
        (uint256 tdB, uint256 trB, uint256 yrB) = facet.getBacking(PID_B);
        emit log_string(label);
        emit log_named_uint("A_totalDeposits", tdA);
        emit log_named_uint("A_tracked", trA);
        emit log_named_uint("A_yieldReserve", yrA);
        emit log_named_uint("A_actual", tokenA.balanceOf(address(facet)));
        emit log_named_uint("B_totalDeposits", tdB);
        emit log_named_uint("B_tracked", trB);
        emit log_named_uint("B_yieldReserve", yrB);
        emit log_named_uint("B_actual", tokenB.balanceOf(address(facet)));
    }


    address internal maker1 = address(0xA11CE);
    address internal maker2 = address(0xB0B);
    address internal taker = address(0xCAFE);

    uint256 internal constant PID_A = 1;
    uint256 internal constant PID_B = 2;

    function setUp() public {
        facet = new CommunityAuctionLifecycleHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.configurePositionNFT(address(nft));
        facet.setTreasury(address(0xC0FFEE));
        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);
    }

    function testLifecycleBackedAfterMakersLeave() public {
        // Mint NFTs and seed pools for two makers.
        uint256 maker1Id = nft.mint(maker1, PID_A);
        uint256 maker2Id = nft.mint(maker2, PID_A);
        bytes32 key1 = nft.getPositionKey(maker1Id);
        bytes32 key2 = nft.getPositionKey(maker2Id);

        uint256 baseA = 20e18;
        uint256 baseB = 400e18; // maintain 1:20 ratio
        facet.seedPool(PID_A, address(tokenA), key1, baseA + 1e18, baseA + 1e18);
        facet.seedPool(PID_B, address(tokenB), key1, baseB + 1e18, baseB + 1e18);
        facet.seedPool(PID_A, address(tokenA), key2, baseA + 1e18, baseA + 1e18);
        facet.seedPool(PID_B, address(tokenB), key2, baseB + 1e18, baseB + 1e18);
        facet.joinPool(key1, PID_A);
        facet.joinPool(key1, PID_B);
        facet.joinPool(key2, PID_A);
        facet.joinPool(key2, PID_B);
        uint256 totalA = 2 * (baseA + 1e18);
        uint256 totalB = 2 * (baseB + 1e18);
        facet.setPoolTotals(PID_A, totalA, totalA);
        facet.setPoolTotals(PID_B, totalB, totalB);
        tokenA.mint(address(facet), totalA);
        _logBacking("after seed");
        tokenA.mint(address(facet), totalA);
        tokenB.mint(address(facet), totalB);

        // Maker 1 creates community auction.
        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: maker1Id,
            poolIdA: PID_A,
            poolIdB: PID_B,
            reserveA: baseA,
            reserveB: baseB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30, // 0.30%
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker1);
        uint256 auctionId = facet.createCommunityAuction(params);

        // Maker 2 joins with matching ratio.
        vm.prank(maker2);
        facet.joinCommunityAuction(auctionId, maker2Id, baseA, baseB);
        _logBacking("after join maker2");

        // Swapper performs two swaps in opposite directions.
        tokenA.mint(taker, 5e18);
        tokenB.mint(taker, 100e18);
        vm.startPrank(taker);
        _logBacking("after swaps");
        tokenA.approve(address(facet), type(uint256).max);
        tokenB.approve(address(facet), type(uint256).max);
        facet.swapExactIn(auctionId, address(tokenA), 1e18, 0, taker);
        facet.swapExactIn(auctionId, address(tokenB), 20e18, 0, taker);
        vm.stopPrank();

        // Both makers leave the auction.
        vm.prank(maker2);
        facet.leaveCommunityAuction(auctionId, maker2Id);
        // Backing should remain intact while another maker is still in.
        _assertBacked(PID_A, tokenA);
        _assertBacked(PID_B, tokenB);
        vm.prank(maker1);
        facet.leaveCommunityAuction(auctionId, maker1Id);
        _logBacking("after leaves");

        // Check backing equals actual balances for both pools.
        _assertBacked(PID_A, tokenA);
        _assertBacked(PID_B, tokenB);
    }

    function _assertBacked(uint256 pid, MockERC20 token) internal {
        (uint256 totalDeposits, uint256 tracked, uint256 yieldReserve) = facet.getBacking(pid);
        uint256 reserved = totalDeposits + yieldReserve;
        uint256 actual = token.balanceOf(address(facet));
        // Tracked should match reserved within 1 wei, and actual should cover reserved.
        assertApproxEqAbs(tracked, reserved, 1, "tracked != reserved");
        assertGe(actual, reserved, "actual backing below reserved");
    }
}

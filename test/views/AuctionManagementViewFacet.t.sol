// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuctionManagementViewFacet} from "../../src/views/AuctionManagementViewFacet.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract AuctionManagementViewHarness is AuctionManagementViewFacet {
    function setPositionNFT(address nftAddr) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nftAddr;
        ns.nftModeEnabled = true;
    }

    function seedPool(
        uint256 pid,
        address underlying,
        uint256 totalDeposits,
        uint256 trackedBalance,
        uint256 feeIndex
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.feeIndex = feeIndex;
        p.maintenanceIndex = feeIndex;
    }

    function seedPositionPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
        LibAppStorage.s().pools[pid].userFeeIndex[positionKey] = LibAppStorage.s().pools[pid].feeIndex;
    }

    function seedAmmAuction(uint256 auctionId, DerivativeTypes.AmmAuction memory data) external {
        LibDerivativeStorage.derivativeStorage().auctions[auctionId] = data;
    }

    function seedCommunityAuction(uint256 auctionId, DerivativeTypes.CommunityAuction memory data) external {
        LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId] = data;
    }

    function seedCommunityMaker(uint256 auctionId, bytes32 positionKey, uint256 share) external {
        LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey].share = share;
        LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey].isParticipant = true;
    }

    function addCommunityAuctionLists(uint256 auctionId, uint256 poolIdA, uint256 poolIdB) external {
        LibDerivativeStorage.addCommunityAuctionGlobal(auctionId);
        LibDerivativeStorage.addCommunityAuctionByPool(poolIdA, auctionId);
        LibDerivativeStorage.addCommunityAuctionByPool(poolIdB, auctionId);
    }

    function addCommunityMakerList(uint256 auctionId, uint256 positionId) external {
        LibDerivativeStorage.addCommunityAuctionMaker(auctionId, positionId);
    }

    function setTreasuryFeesByPool(uint256 pid, uint256 amount) external {
        LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[pid] = amount;
    }
}

contract AuctionManagementViewFacetTest is Test {
    AuctionManagementViewHarness internal viewFacet;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function setUp() public {
        viewFacet = new AuctionManagementViewHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        viewFacet.setPositionNFT(address(nft));
        tokenA = new MockERC20("TokenA", "TA", 18, 1_000_000 ether);
        tokenB = new MockERC20("TokenB", "TB", 6, 1_000_000_000e6);
    }

    function testCommunityAuctionViews() public {
        uint256 auctionId = 1;
        uint256 poolIdA = 11;
        uint256 poolIdB = 12;
        viewFacet.addCommunityAuctionLists(auctionId, poolIdA, poolIdB);

        (uint256[] memory ids, uint256 total) = viewFacet.getActiveCommunityAuctions(0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId);

        (ids, total) = viewFacet.getCommunityAuctionsByPool(poolIdA, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], auctionId);
    }

    function testCommunityAuctionMakersView() public {
        uint256 auctionId = 7;
        uint256 positionId = nft.mint(address(0xBEEF), 1);
        bytes32 positionKey = nft.getPositionKey(positionId);
        viewFacet.addCommunityMakerList(auctionId, positionId);
        viewFacet.seedCommunityMaker(auctionId, positionKey, 42);

        (uint256[] memory ids, bytes32[] memory keys, uint256[] memory shares, uint256 total) =
            viewFacet.getCommunityAuctionMakers(auctionId, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], positionId);
        assertEq(keys[0], positionKey);
        assertEq(shares[0], 42);
    }

    function testAmmAuctionSummaryAndStatus() public {
        vm.warp(2 hours);
        DerivativeTypes.AmmAuction memory auction;
        auction.makerPositionId = 123;
        auction.makerPositionKey = bytes32(uint256(456));
        auction.tokenA = address(tokenA);
        auction.tokenB = address(tokenB);
        auction.reserveA = 10e18;
        auction.reserveB = 20_000e6;
        auction.initialReserveA = 8e18;
        auction.initialReserveB = 18_000e6;
        auction.feeBps = 35;
        auction.active = true;
        auction.finalized = false;
        auction.startTime = uint64(block.timestamp - 1 hours);
        auction.endTime = uint64(block.timestamp + 1 hours);
        auction.makerFeeAAccrued = 1e18;
        auction.treasuryFeeBAccrued = 5_000e6;

        viewFacet.seedAmmAuction(1, auction);

        (
            uint256 makerPositionId,
            bytes32 makerPositionKey,
            uint256 reserveA,
            uint256 reserveB,
            uint256 initialReserveA,
            uint256 initialReserveB,
            uint256 makerFeeA,
            uint256 makerFeeB,
            uint256 treasuryFeeA,
            uint256 treasuryFeeB,
            uint16 feeBps,
            DerivativeTypes.FeeAsset feeAsset,
            uint64 startTime,
            uint64 endTime,
            bool active,
            bool finalized
        ) = viewFacet.getAmmAuctionMakerSummary(1);

        assertEq(makerPositionId, 123);
        assertEq(makerPositionKey, bytes32(uint256(456)));
        assertEq(reserveA, 10e18);
        assertEq(reserveB, 20_000e6);
        assertEq(initialReserveA, 8e18);
        assertEq(initialReserveB, 18_000e6);
        assertEq(makerFeeA, 1e18);
        assertEq(makerFeeB, 0);
        assertEq(treasuryFeeA, 0);
        assertEq(treasuryFeeB, 5_000e6);
        assertEq(feeBps, 35);
        assertEq(uint256(feeAsset), uint256(auction.feeAsset));
        assertEq(startTime, auction.startTime);
        assertEq(endTime, auction.endTime);
        assertTrue(active);
        assertFalse(finalized);

        (bool isActive, bool isFinalized, bool expired, uint256 remaining, bool canFinalize) =
            viewFacet.getAmmAuctionStatus(1);
        assertTrue(isActive);
        assertFalse(isFinalized);
        assertFalse(expired);
        assertGt(remaining, 0);
        assertFalse(canFinalize);
    }

    function testPoolViews() public {
        uint256 pid = 3;
        viewFacet.seedPool(pid, address(tokenA), 1000e18, 900e18, 1e18);
        bytes32 positionKey = bytes32(uint256(999));
        viewFacet.seedPositionPrincipal(pid, positionKey, 250e18);
        viewFacet.setTreasuryFeesByPool(pid, 777);

        (uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 userFeeIndex, uint256 pendingYield) =
            viewFacet.getPoolFeeFlow(pid, positionKey);
        assertEq(totalDeposits, 1000e18);
        assertEq(trackedBalance, 900e18);
        assertEq(feeIndex, 1e18);
        assertEq(userFeeIndex, 1e18);
        assertEq(pendingYield, 0);

        (uint256 liquidity, uint256 deposits, uint256 tracked, uint256 utilizationBps, uint256 feeIdx, uint256 maintIdx) =
            viewFacet.getPoolHealth(pid);
        assertEq(deposits, 1000e18);
        assertEq(tracked, 900e18);
        assertEq(feeIdx, 1e18);
        assertEq(maintIdx, 1e18);
        assertEq(utilizationBps, 10_000);
        assertEq(liquidity, 0);

        (uint256 shareBps, uint256 userPrincipal, uint256 totalPoolDeposits) =
            viewFacet.getPositionFeeShare(pid, positionKey);
        assertEq(shareBps, 2500);
        assertEq(userPrincipal, 250e18);
        assertEq(totalPoolDeposits, 1000e18);

        assertEq(viewFacet.getTreasuryFeesByPool(pid), 777);
    }
}

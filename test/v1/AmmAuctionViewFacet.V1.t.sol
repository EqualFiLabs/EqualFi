// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AmmAuctionViewFacet} from "../../src/views/AmmAuctionViewFacet.sol";
import {AuctionManagementViewFacet} from "../../src/views/AuctionManagementViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract LocalAuctionMgmtMockERC20V1 is ERC20 {
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

contract AmmAuctionViewV1Harness is AmmAuctionViewFacet, AuctionManagementViewFacet {
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
        uint256 feeIndex,
        uint256 maintenanceIndex,
        uint256 yieldReserve,
        uint256 activeCreditPrincipalTotal
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.feeIndex = feeIndex;
        p.maintenanceIndex = maintenanceIndex;
        p.yieldReserve = yieldReserve;
        p.activeCreditPrincipalTotal = activeCreditPrincipalTotal;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function seedPositionState(
        uint256 pid,
        bytes32 positionKey,
        uint256 principal,
        uint256 userFeeIndex,
        uint256 userMaintenanceIndex,
        uint256 accruedYield
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = userFeeIndex;
        p.userMaintenanceIndex[positionKey] = userMaintenanceIndex;
        p.userAccruedYield[positionKey] = accruedYield;
    }

    function seedAmmAuction(uint256 auctionId, DerivativeTypes.AmmAuction memory data) external {
        LibDerivativeStorage.derivativeStorage().auctions[auctionId] = data;
    }

    function seedCommunityAuction(uint256 auctionId, DerivativeTypes.CommunityAuction memory data, bool addIndexes)
        external
    {
        LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId] = data;
        if (addIndexes) {
            LibDerivativeStorage.addCommunityAuctionGlobal(auctionId);
            LibDerivativeStorage.addCommunityAuctionByPool(data.poolIdA, auctionId);
            LibDerivativeStorage.addCommunityAuctionByPool(data.poolIdB, auctionId);
            LibDerivativeStorage.addCommunityAuctionByPair(data.tokenA, data.tokenB, auctionId);
        }
    }

    function seedCommunityMaker(
        uint256 auctionId,
        uint256 positionId,
        bytes32 positionKey,
        uint256 share,
        uint256 feeIndexSnapshotA,
        uint256 feeIndexSnapshotB,
        bool addIndex
    ) external {
        LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey] = DerivativeTypes
            .MakerPosition({
            share: share,
            feeIndexSnapshotA: feeIndexSnapshotA,
            feeIndexSnapshotB: feeIndexSnapshotB,
            initialContributionA: 0,
            initialContributionB: 0,
            isParticipant: true
        });
        if (addIndex) {
            LibDerivativeStorage.addCommunityAuctionMaker(auctionId, positionId);
        }
    }

    function setTreasuryFeesByPool(uint256 pid, uint256 amount) external {
        LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[pid] = amount;
    }
}

contract AmmAuctionViewFacetV1Test is Test {
    AmmAuctionViewV1Harness internal harness;
    PositionNFT internal nft;
    LocalAuctionMgmtMockERC20V1 internal tokenA;
    LocalAuctionMgmtMockERC20V1 internal tokenB;

    function setUp() public {
        vm.warp(10 days);
        harness = new AmmAuctionViewV1Harness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        tokenA = new LocalAuctionMgmtMockERC20V1("TokenA", "TA", 18);
        tokenB = new LocalAuctionMgmtMockERC20V1("TokenB", "TB", 18);
    }

    function test_previewSwap_andAmmAuctionManagementStatusSummary() public {
        uint256 makerPositionId = nft.mint(address(0xA11CE), 1);
        bytes32 makerKey = nft.getPositionKey(makerPositionId);

        DerivativeTypes.AmmAuction memory auction;
        auction.makerPositionId = makerPositionId;
        auction.makerPositionKey = makerKey;
        auction.poolIdA = 1;
        auction.poolIdB = 2;
        auction.tokenA = address(tokenA);
        auction.tokenB = address(tokenB);
        auction.reserveA = 10 ether;
        auction.reserveB = 20 ether;
        auction.initialReserveA = 10 ether;
        auction.initialReserveB = 20 ether;
        auction.startTime = uint64(block.timestamp - 1 hours);
        auction.endTime = uint64(block.timestamp + 1 hours);
        auction.feeBps = 30;
        auction.feeAsset = DerivativeTypes.FeeAsset.TokenIn;
        auction.invariantMode = DerivativeTypes.InvariantMode.Volatile;
        auction.makerFeeAAccrued = 1 ether;
        auction.treasuryFeeBAccrued = 2 ether;
        auction.active = true;
        auction.finalized = false;
        auction.tokenADecimals = 18;
        auction.tokenBDecimals = 18;

        harness.seedAmmAuction(1, auction);

        (uint256 out, uint256 fee) = harness.previewSwap(1, address(tokenA), 1 ether);
        assertGt(out, 0);
        assertEq(fee, 3e15);

        (out, fee) = harness.previewSwap(1, address(0xDEAD), 1 ether);
        assertEq(out, 0);
        assertEq(fee, 0);

        (bool active, bool finalized, bool expired, uint256 timeRemaining, bool canFinalize) =
            harness.getAmmAuctionStatus(1);
        assertTrue(active);
        assertFalse(finalized);
        assertFalse(expired);
        assertGt(timeRemaining, 0);
        assertFalse(canFinalize);

        (
            uint256 gotMakerPositionId,
            bytes32 gotMakerKey,
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
            bool isActive,
            bool isFinalized
        ) = harness.getAmmAuctionMakerSummary(1);

        assertEq(gotMakerPositionId, makerPositionId);
        assertEq(gotMakerKey, makerKey);
        assertEq(reserveA, 10 ether);
        assertEq(reserveB, 20 ether);
        assertEq(initialReserveA, 10 ether);
        assertEq(initialReserveB, 20 ether);
        assertEq(makerFeeA, 1 ether);
        assertEq(makerFeeB, 0);
        assertEq(treasuryFeeA, 0);
        assertEq(treasuryFeeB, 2 ether);
        assertEq(feeBps, 30);
        assertEq(uint256(feeAsset), uint256(DerivativeTypes.FeeAsset.TokenIn));
        assertEq(startTime, auction.startTime);
        assertEq(endTime, auction.endTime);
        assertTrue(isActive);
        assertFalse(isFinalized);

        vm.warp(block.timestamp + 2 hours);
        (active, finalized, expired,, canFinalize) = harness.getAmmAuctionStatus(1);
        assertTrue(active);
        assertFalse(finalized);
        assertTrue(expired);
        assertTrue(canFinalize);
    }

    function test_auctionManagementCommunityPagesMakersAndPoolViews() public {
        uint256 positionId = nft.mint(address(0xBEEF), 1);
        bytes32 positionKey = nft.getPositionKey(positionId);

        DerivativeTypes.CommunityAuction memory cAuction;
        cAuction.creatorPositionId = positionId;
        cAuction.creatorPositionKey = positionKey;
        cAuction.poolIdA = 11;
        cAuction.poolIdB = 12;
        cAuction.tokenA = address(tokenA);
        cAuction.tokenB = address(tokenB);
        cAuction.reserveA = 8 ether;
        cAuction.reserveB = 16 ether;
        cAuction.totalShares = 1000;
        cAuction.makerCount = 1;
        cAuction.feeIndexA = 2e18;
        cAuction.feeIndexB = 3e18;
        cAuction.startTime = uint64(block.timestamp - 1 hours);
        cAuction.endTime = uint64(block.timestamp + 1 hours);
        cAuction.active = true;

        harness.seedCommunityAuction(1, cAuction, true);
        harness.seedCommunityMaker(1, positionId, positionKey, 700, 0, 0, true);

        (uint256[] memory ids, uint256 total) = harness.getActiveCommunityAuctions(0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        (ids, total) = harness.getCommunityAuctionsByPair(address(tokenA), address(tokenB), 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        (ids, total) = harness.getCommunityAuctionsByPool(11, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        (uint256[] memory makerIds, bytes32[] memory makerKeys, uint256[] memory shares, uint256 makerTotal) =
            harness.getCommunityAuctionMakers(1, 0, 10);
        assertEq(makerTotal, 1);
        assertEq(makerIds.length, 1);
        assertEq(makerKeys.length, 1);
        assertEq(shares.length, 1);
        assertEq(makerIds[0], positionId);
        assertEq(makerKeys[0], positionKey);
        assertEq(shares[0], 700);

        tokenA.mint(address(harness), 750 ether);
        harness.seedPool(11, address(tokenA), 1000 ether, 900 ether, 11e17, 1e18, 3 ether, 2 ether);
        harness.seedPositionState(11, positionKey, 250 ether, 1e18, 1e18, 0);
        harness.setTreasuryFeesByPool(11, 777);

        (uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 userFeeIndex, uint256 pendingYield) =
            harness.getPoolFeeFlow(11, positionKey);
        assertEq(totalDeposits, 1000 ether);
        assertEq(trackedBalance, 900 ether);
        assertEq(feeIndex, 11e17);
        assertEq(userFeeIndex, 1e18);
        assertEq(pendingYield, 25 ether);

        (uint256 liquidity, uint256 deposits, uint256 tracked, uint256 utilizationBps, uint256 feeIdx, uint256 maintIdx)
        = harness.getPoolHealth(11);
        assertEq(liquidity, 750 ether);
        assertEq(deposits, 1000 ether);
        assertEq(tracked, 900 ether);
        assertEq(utilizationBps, 2500);
        assertEq(feeIdx, 11e17);
        assertEq(maintIdx, 1e18);

        (uint256 shareBps, uint256 userPrincipal, uint256 poolDeposits) = harness.getPositionFeeShare(11, positionKey);
        assertEq(shareBps, 2500);
        assertEq(userPrincipal, 250 ether);
        assertEq(poolDeposits, 1000 ether);
        assertEq(harness.getTreasuryFeesByPool(11), 777);

        (
            uint256 backingDeposits,
            uint256 backingTracked,
            uint256 backingYieldReserve,
            uint256 backingActiveCredit,
            uint256 actualBalance
        ) = harness.getPoolBacking(11);
        assertEq(backingDeposits, 1000 ether);
        assertEq(backingTracked, 900 ether);
        assertEq(backingYieldReserve, 3 ether);
        assertEq(backingActiveCredit, 2 ether);
        assertEq(actualBalance, 750 ether);

        vm.expectRevert("AuctionView: uninit pool");
        harness.getPoolHealth(999);
    }
}

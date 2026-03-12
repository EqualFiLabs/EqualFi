// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CommunityAuctionViewFacet} from "../../src/views/CommunityAuctionViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";

contract LocalCommunityViewMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract CommunityAuctionViewV1Harness is CommunityAuctionViewFacet {
    function seedCommunityAuction(uint256 auctionId, DerivativeTypes.CommunityAuction memory data) external {
        LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId] = data;
    }

    function seedMaker(
        uint256 auctionId,
        bytes32 positionKey,
        uint256 share,
        uint256 feeIndexSnapshotA,
        uint256 feeIndexSnapshotB
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
    }
}

contract CommunityAuctionViewFacetV1Test is Test {
    CommunityAuctionViewV1Harness internal harness;
    LocalCommunityViewMockERC20V1 internal tokenA;
    LocalCommunityViewMockERC20V1 internal tokenB;

    function setUp() public {
        vm.warp(10 days);
        harness = new CommunityAuctionViewV1Harness();
        tokenA = new LocalCommunityViewMockERC20V1("TokenA", "A", 18);
        tokenB = new LocalCommunityViewMockERC20V1("TokenB", "B", 18);
    }

    function test_previewJoinAndSwap_guardsAndActivePath() public {
        DerivativeTypes.CommunityAuction memory auction;
        auction.tokenA = address(tokenA);
        auction.tokenB = address(tokenB);
        auction.reserveA = 10 ether;
        auction.reserveB = 20 ether;
        auction.totalShares = 100;
        auction.feeBps = 30;
        auction.feeAsset = DerivativeTypes.FeeAsset.TokenIn;
        auction.invariantMode = DerivativeTypes.InvariantMode.Volatile;
        auction.tokenADecimals = 18;
        auction.tokenBDecimals = 18;
        auction.startTime = uint64(block.timestamp - 1 hours);
        auction.endTime = uint64(block.timestamp + 1 hours);
        auction.active = true;
        auction.finalized = false;

        harness.seedCommunityAuction(1, auction);

        assertEq(harness.previewJoin(1, 0), 0);
        assertEq(harness.previewJoin(1, 2 ether), 4 ether);

        (uint256 amountOut, uint256 feeAmount) = harness.previewCommunitySwap(1, address(tokenA), 1 ether);
        assertGt(amountOut, 0);
        assertEq(feeAmount, 3e15);

        (amountOut, feeAmount) = harness.previewCommunitySwap(1, address(0xDEAD), 1 ether);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);

        DerivativeTypes.CommunityAuction memory notStarted = auction;
        notStarted.startTime = uint64(block.timestamp + 1 days);
        notStarted.endTime = uint64(block.timestamp + 2 days);
        harness.seedCommunityAuction(2, notStarted);
        (amountOut, feeAmount) = harness.previewCommunitySwap(2, address(tokenA), 1 ether);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);
    }

    function test_previewLeaveAndMakerShare_includesPendingFees() public {
        bytes32 makerKey = keccak256("maker");

        DerivativeTypes.CommunityAuction memory auction;
        auction.tokenA = address(tokenA);
        auction.tokenB = address(tokenB);
        auction.reserveA = 100 ether;
        auction.reserveB = 200 ether;
        auction.totalShares = 1000;
        auction.makerCount = 1;
        auction.feeIndexA = 2e18;
        auction.feeIndexB = 3e18;
        auction.indexFeeAAccrued = 10 ether;
        auction.activeCreditFeeAAccrued = 5 ether;
        auction.indexFeeBAccrued = 20 ether;
        auction.activeCreditFeeBAccrued = 10 ether;
        auction.active = true;
        auction.startTime = uint64(block.timestamp - 1 hours);
        auction.endTime = uint64(block.timestamp + 1 hours);
        harness.seedCommunityAuction(1, auction);

        harness.seedMaker(1, makerKey, 200, 0, 0);

        (uint256 share, uint256 pendingFeesA, uint256 pendingFeesB) = harness.getMakerShare(1, makerKey);
        assertEq(share, 200);
        assertEq(pendingFeesA, 400);
        assertEq(pendingFeesB, 600);

        (uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB) = harness.previewLeave(1, makerKey);
        assertEq(withdrawA, 17 ether);
        assertEq(withdrawB, 34 ether);
        assertEq(feesA, 400);
        assertEq(feesB, 600);
        assertEq(harness.getTotalMakers(1), 1);
    }

    function test_getCommunityAuction_andZeroCases() public {
        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(999);
        assertEq(auction.reserveA, 0);
        assertEq(auction.reserveB, 0);

        (uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB) =
            harness.previewLeave(999, keccak256("none"));
        assertEq(withdrawA, 0);
        assertEq(withdrawB, 0);
        assertEq(feesA, 0);
        assertEq(feesB, 0);
    }
}

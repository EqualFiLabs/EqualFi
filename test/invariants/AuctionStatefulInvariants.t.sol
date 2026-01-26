// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AmmAuctionHarness} from "../derivatives/AmmAuctionFacetProperty.t.sol";
import {CommunityAuctionHarness} from "../derivatives/CommunityAuctionFacetProperty.t.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract AmmAuctionStatefulHandler is Test {
    AmmAuctionHarness internal harness;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal taker;
    uint256 internal auctionId;

    uint256 public lastK;

    constructor(
        AmmAuctionHarness harness_,
        MockERC20 tokenA_,
        MockERC20 tokenB_,
        address taker_,
        uint256 auctionId_
    ) {
        harness = harness_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        taker = taker_;
        auctionId = auctionId_;
        lastK = _currentK();
    }

    function swapExactIn(uint256 amountSeed, uint256 tokenSeed) external {
        _snapshotK();
        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        bool inIsA = tokenSeed % 2 == 0;
        MockERC20 tokenIn = inIsA ? tokenA : tokenB;
        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 maxIn = reserveIn / 5;
        if (maxIn == 0) {
            return;
        }
        uint256 amountIn = bound(amountSeed, 1, maxIn);
        tokenIn.mint(taker, amountIn);
        vm.prank(taker);
        tokenIn.approve(address(harness), amountIn);
        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenIn), amountIn, 0, taker);
    }

    function _snapshotK() internal {
        lastK = _currentK();
    }

    function _currentK() internal view returns (uint256) {
        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        return Math.mulDiv(auction.reserveA, auction.reserveB, 1);
    }
}

contract AmmAuctionStatefulInvariantTest is StdInvariant, Test {
    AmmAuctionHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    AmmAuctionStatefulHandler internal handler;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal treasury = address(0xC0FFEE);

    uint256 internal auctionId;
    bytes32 internal makerKey;

    uint256 internal principalA;
    uint256 internal principalB;

    function setUp() public {
        harness = new AmmAuctionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);

        uint256 makerTokenId = nft.mint(maker, 1);
        makerKey = nft.getPositionKey(makerTokenId);

        principalA = 1_000_000 ether;
        principalB = 1_000_000 ether;
        harness.seedPool(1, address(tokenA), makerKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerKey, principalB, principalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 100_000 ether,
            reserveB: 200_000 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 7 days),
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        auctionId = harness.createAuction(params);

        vm.prank(taker);
        tokenA.approve(address(harness), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(harness), type(uint256).max);

        handler = new AmmAuctionStatefulHandler(harness, tokenA, tokenB, taker, auctionId);
        targetContract(address(handler));
    }

    function invariant_reservesNonZero() public {
        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        assertGt(auction.reserveA, 0);
        assertGt(auction.reserveB, 0);
    }

    function invariant_kNonDecreasing() public {
        DerivativeTypes.AmmAuction memory auction = harness.getAuction(auctionId);
        uint256 currentK = Math.mulDiv(auction.reserveA, auction.reserveB, 1);
        assertGe(currentK, handler.lastK());
    }

    function invariant_principalStable() public {
        assertEq(harness.getUserPrincipal(1, makerKey), principalA);
        assertEq(harness.getUserPrincipal(2, makerKey), principalB);
        assertEq(harness.getTotalDeposits(1), principalA);
        assertEq(harness.getTotalDeposits(2), principalB);
    }
}

contract CommunityAuctionStatefulHandler is Test {
    CommunityAuctionHarness internal harness;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal taker;
    uint256 internal auctionId;

    constructor(
        CommunityAuctionHarness harness_,
        MockERC20 tokenA_,
        MockERC20 tokenB_,
        address taker_,
        uint256 auctionId_
    ) {
        harness = harness_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        taker = taker_;
        auctionId = auctionId_;
    }

    function swapExactIn(uint256 amountSeed, uint256 tokenSeed) external {
        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        bool inIsA = tokenSeed % 2 == 0;
        MockERC20 tokenIn = inIsA ? tokenA : tokenB;
        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 maxIn = reserveIn / 5;
        if (maxIn == 0) {
            return;
        }
        uint256 amountIn = bound(amountSeed, 1, maxIn);
        tokenIn.mint(taker, amountIn);
        vm.prank(taker);
        tokenIn.approve(address(harness), amountIn);
        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenIn), amountIn, 0, taker);
    }
}

contract CommunityAuctionStatefulInvariantTest is StdInvariant, Test {
    CommunityAuctionHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    CommunityAuctionStatefulHandler internal handler;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    uint256 internal auctionId;
    bytes32 internal makerKey;

    uint256 internal principalA;
    uint256 internal principalB;

    function setUp() public {
        harness = new CommunityAuctionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        harness.setMakerShareBps(7000);
        harness.setTreasury(address(0xC0FFEE));

        uint256 makerTokenId = nft.mint(maker, 1);
        makerKey = nft.getPositionKey(makerTokenId);

        principalA = 1_000_000 ether;
        principalB = 1_000_000 ether;
        harness.seedPool(1, address(tokenA), makerKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerKey, principalB, principalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 100_000 ether,
            reserveB: 200_000 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 7 days),
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        auctionId = harness.createCommunityAuction(params);

        vm.prank(taker);
        tokenA.approve(address(harness), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(harness), type(uint256).max);

        handler = new CommunityAuctionStatefulHandler(harness, tokenA, tokenB, taker, auctionId);
        targetContract(address(handler));
    }

    function invariant_auctionActive() public {
        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        assertTrue(auction.active);
        assertEq(auction.makerCount, 1);
        assertGt(auction.reserveA, 0);
        assertGt(auction.reserveB, 0);
    }

    function invariant_makerShareMatchesTotal() public {
        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        (uint256 makerShare,,) = harness.getMakerShare(auctionId, makerKey);
        assertEq(makerShare, auction.totalShares);
    }

    function invariant_principalStable() public {
        (uint256 totalDepositsA,,) = harness.getPoolBacking(1);
        (uint256 totalDepositsB,,) = harness.getPoolBacking(2);
        assertEq(totalDepositsA, principalA);
        assertEq(totalDepositsB, principalB);
    }
}

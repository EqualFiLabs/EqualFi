// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract CommunityAuctionGasTest is Test {
    CommunityAuctionGasHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal joiner = address(0xB0B);
    address internal taker = address(0xC0C0);
    address internal treasury = address(0xC0FFEE);

    function setUp() public {
        harness = new CommunityAuctionGasHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
    }

    function _setupMakerPosition(uint256 principal, uint256 tracked)
        internal
        returns (uint256 makerTokenId, bytes32 positionKey)
    {
        makerTokenId = nft.mint(maker, 1);
        positionKey = nft.getPositionKey(makerTokenId);
        harness.seedPool(1, address(tokenA), positionKey, principal, tracked);
        harness.seedPool(2, address(tokenB), positionKey, principal, tracked);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function _setupJoinerPosition(uint256 principal, uint256 tracked)
        internal
        returns (uint256 joinerTokenId, bytes32 positionKey)
    {
        joinerTokenId = nft.mint(joiner, 1);
        positionKey = nft.getPositionKey(joinerTokenId);
        harness.seedPool(1, address(tokenA), positionKey, principal, tracked);
        harness.seedPool(2, address(tokenB), positionKey, principal, tracked);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function _createAuction(uint256 makerTokenId) internal returns (uint256 auctionId) {
        vm.prank(maker);
        auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );
    }

    function testGasCreateCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(10e18, 50e18);
        vm.resumeGasMetering();

        _createAuction(makerTokenId);
    }

    function testGasJoinCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(10e18, 50e18);
        uint256 auctionId = _createAuction(makerTokenId);
        (uint256 joinerTokenId,) = _setupJoinerPosition(10e18, 50e18);
        uint256 amountA = 1e18;
        uint256 amountB = harness.previewJoin(auctionId, amountA);
        vm.resumeGasMetering();

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, amountB);
    }

    function testGasLeaveCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(10e18, 50e18);
        uint256 auctionId = _createAuction(makerTokenId);
        (uint256 joinerTokenId,) = _setupJoinerPosition(10e18, 50e18);
        uint256 amountA = 1e18;
        uint256 amountB = harness.previewJoin(auctionId, amountA);
        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, amountB);
        vm.resumeGasMetering();

        vm.prank(joiner);
        harness.leaveCommunityAuction(auctionId, joinerTokenId);
    }

    function testGasSwapExactInCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(20e18, 100e18);
        uint256 auctionId = _createAuction(makerTokenId);
        uint256 amountIn = 1e18;
        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);
        vm.resumeGasMetering();

        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, 1, taker);
    }

    function testGasFinalizeCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(10e18, 50e18);
        uint256 auctionId = _createAuction(makerTokenId);
        vm.warp(block.timestamp + 1 days);
        vm.resumeGasMetering();

        harness.finalizeAuction(auctionId);
    }

    function testGasClaimFeesCommunityAuction() public {
        vm.pauseGasMetering();
        (uint256 makerTokenId,) = _setupMakerPosition(20e18, 100e18);
        uint256 auctionId = _createAuction(makerTokenId);
        uint256 amountIn = 1e18;
        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);
        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, 1, taker);
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.claimFees(auctionId, makerTokenId);
    }
}

contract CommunityAuctionGasHarness is CommunityAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
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
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
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
}

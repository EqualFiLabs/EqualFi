// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract CommunityAuctionInvariantModeTest is Test {
    struct RawCreateCommunityAuctionParams {
        uint256 positionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        DerivativeTypes.FeeAsset feeAsset;
        uint8 invariantMode;
    }

    CommunityAuctionInvariantHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal treasury = address(0xBEEF);

    function setUp() public {
        harness = new CommunityAuctionInvariantHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);
    }

    function test_CreateCommunityAuctionRejectsInvalidInvariantMode() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), makerKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), makerKey, 3e18, 3e18);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        RawCreateCommunityAuctionParams memory rawParams = RawCreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 1e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: uint8(DerivativeTypes.InvariantMode.Stable) + 1
        });

        bytes memory callData = abi.encodeWithSelector(harness.createCommunityAuction.selector, rawParams);
        vm.prank(maker);
        (bool ok,) = address(harness).call(callData);
        assertFalse(ok, "invalid mode must revert");
    }

    function test_StableCommunityMode_PreviewSwapMatchesExecution() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6, 0);
        MockERC20 dai = new MockERC20("DAI", "DAI", 18, 0);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveUsdc = 1_000_000e6;
        uint256 reserveDai = 1_000_000e18;
        harness.seedPool(1, address(usdc), makerKey, reserveUsdc + 100e6, reserveUsdc + 100e6);
        harness.seedPool(2, address(dai), makerKey, reserveDai + 100e18, reserveDai + 100e18);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
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
        (uint256 previewOut, uint256 previewFee) = harness.previewCommunitySwap(auctionId, address(usdc), amountIn);
        uint256 inAfterFee = Math.mulDiv(amountIn, 10_000 - 30, 10_000);
        uint256 expectedFee = amountIn - inAfterFee;
        assertGt(previewOut, 0, "stable preview out");
        assertEq(previewFee, expectedFee, "stable preview fee");

        usdc.mint(taker, amountIn);
        vm.prank(taker);
        usdc.approve(address(harness), amountIn);

        vm.prank(taker);
        uint256 amountOut = harness.swapExactIn(auctionId, address(usdc), amountIn, amountIn, previewOut, taker);
        assertEq(amountOut, previewOut, "stable preview/execution parity");
    }

    function test_VolatileCommunityMode_PreviewMatchesLegacyMathSnapshot() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 50e18;
        uint256 reserveB = 100e18;
        harness.seedPool(1, address(tokenA), makerKey, reserveA + 10e18, reserveA + 10e18);
        harness.seedPool(2, address(tokenB), makerKey, reserveB + 10e18, reserveB + 10e18);
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
                feeBps: 25,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn,
                invariantMode: DerivativeTypes.InvariantMode.Volatile
            })
        );

        uint256 amountIn = 10e18;
        uint256 amountInWithFee = Math.mulDiv(amountIn, 10_000 - 25, 10_000);
        uint256 expectedFee = amountIn - amountInWithFee;
        uint256 expectedOut = Math.mulDiv(reserveB, amountInWithFee, reserveA + amountInWithFee);

        (uint256 previewOut, uint256 previewFee) = harness.previewCommunitySwap(auctionId, address(tokenA), amountIn);
        assertEq(previewOut, expectedOut, "volatile output snapshot");
        assertEq(previewFee, expectedFee, "volatile fee snapshot");

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        uint256 amountOut = harness.swapExactIn(auctionId, address(tokenA), amountIn, amountIn, expectedOut, taker);
        assertEq(amountOut, expectedOut, "volatile preview/execution parity");
    }
}

contract CommunityAuctionInvariantHarness is CommunityAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps = shareBps;
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
}

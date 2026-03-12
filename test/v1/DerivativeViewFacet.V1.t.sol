// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DerivativeViewFacet} from "../../src/views/DerivativeViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockDerivativeViewTokenV1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract DerivativeViewV1Harness is DerivativeViewFacet {
    function configurePositionNFT(address nftAddr) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nftAddr;
        ns.nftModeEnabled = true;
    }

    function seedAmmAuction(uint256 auctionId, DerivativeTypes.AmmAuction memory auction, bool addIndexes) external {
        LibDerivativeStorage.derivativeStorage().auctions[auctionId] = auction;
        if (addIndexes) {
            LibDerivativeStorage.addAuction(auction.makerPositionKey, auctionId);
            LibDerivativeStorage.addAuctionGlobal(auctionId);
            LibDerivativeStorage.addAuctionByPool(auction.poolIdA, auctionId);
            LibDerivativeStorage.addAuctionByPool(auction.poolIdB, auctionId);
            LibDerivativeStorage.addAuctionByToken(auction.tokenA, auctionId);
            LibDerivativeStorage.addAuctionByToken(auction.tokenB, auctionId);
            LibDerivativeStorage.addAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
        }
    }

    function seedOptionSeries(uint256 seriesId, DerivativeTypes.OptionSeries memory series, uint256 contractSize, bool addIndex)
        external
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        ds.optionSeries[seriesId] = series;
        ds.optionContractSize[seriesId] = contractSize;
        if (addIndex) {
            LibDerivativeStorage.addOptionSeries(series.makerPositionKey, seriesId);
        }
    }

    function seedFuturesSeries(
        uint256 seriesId,
        DerivativeTypes.FuturesSeries memory series,
        uint256 contractSize,
        bool addIndex
    ) external {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        ds.futuresSeries[seriesId] = series;
        ds.futuresContractSize[seriesId] = contractSize;
        if (addIndex) {
            LibDerivativeStorage.addFuturesSeries(series.makerPositionKey, seriesId);
        }
    }
}

contract DerivativeViewFacetV1Test is Test {
    DerivativeViewV1Harness internal harness;
    PositionNFT internal nft;
    MockDerivativeViewTokenV1 internal tokenA;
    MockDerivativeViewTokenV1 internal tokenB;
    MockDerivativeViewTokenV1 internal tokenC;

    uint256 internal makerPositionId1;
    uint256 internal makerPositionId2;
    bytes32 internal makerKey1;
    bytes32 internal makerKey2;

    function setUp() public {
        harness = new DerivativeViewV1Harness();
        vm.warp(3 days);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        tokenA = new MockDerivativeViewTokenV1("TokenA", "A", 18);
        tokenB = new MockDerivativeViewTokenV1("TokenB", "B", 18);
        tokenC = new MockDerivativeViewTokenV1("TokenC", "C", 6);

        makerPositionId1 = nft.mint(address(0x1111), 1);
        makerPositionId2 = nft.mint(address(0x2222), 2);
        makerKey1 = nft.getPositionKey(makerPositionId1);
        makerKey2 = nft.getPositionKey(makerPositionId2);
    }

    function test_auctionViews_previewAndBestRoute() public {
        DerivativeTypes.AmmAuction memory auction1 = _auction(
            makerKey1, makerPositionId1, 1, 2, 10e18, 20e18, uint64(block.timestamp - 1 hours), uint64(block.timestamp + 1 hours)
        );
        auction1.feeBps = 30;
        auction1.makerFeeAAccrued = 5e15;

        DerivativeTypes.AmmAuction memory auction2 = _auction(
            makerKey2, makerPositionId2, 3, 4, 10e18, 30e18, uint64(block.timestamp - 1 hours), uint64(block.timestamp + 1 hours)
        );
        auction2.feeBps = 30;
        auction2.makerFeeBAccrued = 7e15;

        DerivativeTypes.AmmAuction memory auction3 = _auction(
            makerKey1, makerPositionId1, 5, 6, 10e18, 50e18, uint64(block.timestamp - 2 days), uint64(block.timestamp - 1 days)
        );
        auction3.feeBps = 30;

        harness.seedAmmAuction(1, auction1, true);
        harness.seedAmmAuction(2, auction2, true);
        harness.seedAmmAuction(3, auction3, true);

        DerivativeTypes.AmmAuction memory read1 = harness.getAmmAuction(1);
        assertEq(read1.reserveA, 10e18);
        assertEq(read1.reserveB, 20e18);
        (uint256 makerFeeA, uint256 makerFeeB) = harness.getAuctionFees(1);
        assertEq(makerFeeA, 5e15);
        assertEq(makerFeeB, 0);

        (uint256[] memory ids, uint256 total) = harness.getActiveAuctions(0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);

        (ids, total) = harness.getAuctionsByPosition(makerKey1, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);

        (ids, total) = harness.getAuctionsByPositionId(makerPositionId1, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);

        (ids, total) = harness.getAuctionsByPool(1, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], 1);

        (ids, total) = harness.getAuctionsByToken(address(tokenA), 0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);

        (ids, total) = harness.getAuctionsByPair(address(tokenA), address(tokenB), 0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);

        (
            bool active,
            bool expired,
            uint64 startTime,
            uint64 endTime,
            address metaTokenA,
            address metaTokenB,
            uint256 reserveA,
            uint256 reserveB,
            uint256 priceAInB,
            uint256 priceBInA,
            uint256 timeRemaining
        ) = harness.getAuctionMeta(1);
        assertTrue(active);
        assertFalse(expired);
        assertEq(startTime, auction1.startTime);
        assertEq(metaTokenA, address(tokenA));
        assertEq(metaTokenB, address(tokenB));
        assertEq(reserveA, 10e18);
        assertEq(reserveB, 20e18);
        assertEq(priceAInB, 2e18);
        assertEq(priceBInA, 5e17);
        assertEq(timeRemaining, endTime - block.timestamp);

        uint256 amountIn = 1e18;
        uint256 amountInWithFee = Math.mulDiv(amountIn, 10_000 - 30, 10_000);
        uint256 expectedOut = Math.mulDiv(20e18, amountInWithFee, 10e18 + amountInWithFee);
        (uint256 out, uint256 feeAmount, uint256 minOut) =
            harness.previewSwapWithSlippage(1, address(tokenA), amountIn, 100);
        assertEq(out, expectedOut);
        assertEq(feeAmount, amountIn - amountInWithFee);
        assertEq(minOut, Math.mulDiv(out, 9900, 10_000));

        (, , uint256 minOutClamped) = harness.previewSwapWithSlippage(1, address(tokenA), amountIn, 20_000);
        assertEq(minOutClamped, 0);

        (uint256 outInvalid, uint256 feeInvalid, uint256 minOutInvalid) =
            harness.previewSwapWithSlippage(1, address(tokenC), amountIn, 100);
        assertEq(outInvalid, 0);
        assertEq(feeInvalid, 0);
        assertEq(minOutInvalid, 0);

        (uint256 bestId, uint256 bestOut, uint256 checked) =
            harness.findBestAuctionExactIn(address(tokenA), address(tokenB), amountIn, 0, 10);
        assertEq(bestId, 2);
        assertGt(bestOut, out);
        assertEq(checked, 3);
    }

    function test_optionAndFuturesViews_pagesAndSelectors() public {
        DerivativeTypes.OptionSeries memory option = DerivativeTypes.OptionSeries({
            makerPositionKey: makerKey1,
            makerPositionId: makerPositionId1,
            underlyingPoolId: 11,
            strikePoolId: 12,
            underlyingAsset: address(tokenA),
            strikeAsset: address(tokenB),
            strikePrice: 2e18,
            expiry: uint64(block.timestamp + 7 days),
            totalSize: 5e18,
            remaining: 3e18,
            collateralLocked: 3e18,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0,
            isCall: true,
            isAmerican: true,
            reclaimed: false
        });
        harness.seedOptionSeries(11, option, 5, true);

        DerivativeTypes.FuturesSeries memory futures = DerivativeTypes.FuturesSeries({
            makerPositionKey: makerKey1,
            makerPositionId: makerPositionId1,
            underlyingPoolId: 21,
            quotePoolId: 22,
            underlyingAsset: address(tokenA),
            quoteAsset: address(tokenC),
            forwardPrice: 15e17,
            expiry: uint64(block.timestamp + 10 days),
            totalSize: 8e18,
            remaining: 6e18,
            underlyingLocked: 6e18,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0,
            graceUnlockTime: uint64(block.timestamp + 12 days),
            isEuropean: true,
            reclaimed: false
        });
        harness.seedFuturesSeries(21, futures, 7, true);

        DerivativeTypes.OptionSeries memory gotOption = harness.getOptionSeries(11);
        assertEq(gotOption.makerPositionId, makerPositionId1);
        assertEq(gotOption.remaining, 3e18);
        (uint256 optionLocked, uint256 optionRemaining) = harness.getOptionSeriesCollateral(11);
        assertEq(optionLocked, 3e18);
        assertEq(optionRemaining, 3e18);
        assertEq(harness.getOptionContractSize(11), 5);

        DerivativeTypes.FuturesSeries memory gotFutures = harness.getFuturesSeries(21);
        assertEq(gotFutures.makerPositionId, makerPositionId1);
        assertEq(gotFutures.remaining, 6e18);
        (uint256 underlyingLocked, uint256 futuresRemaining) = harness.getFuturesCollateral(21);
        assertEq(underlyingLocked, 6e18);
        assertEq(futuresRemaining, 6e18);
        assertEq(harness.getFuturesContractSize(21), 7);
        assertEq(harness.getGraceUnlockTime(21), futures.graceUnlockTime);

        (uint256[] memory ids, uint256 total) = harness.getOptionSeriesByPosition(makerKey1, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 11);

        (ids, total) = harness.getOptionSeriesByPositionId(makerPositionId1, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], 11);

        (ids, total) = harness.getFuturesSeriesByPosition(makerKey1, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], 21);

        (ids, total) = harness.getFuturesSeriesByPositionId(makerPositionId1, 0, 10);
        assertEq(total, 1);
        assertEq(ids[0], 21);

        bytes4[] memory selectors = harness.selectors();
        assertEq(selectors.length, 22);
        assertEq(selectors[0], DerivativeViewFacet.getAmmAuction.selector);
        assertEq(selectors[21], DerivativeViewFacet.getFuturesSeriesByPositionId.selector);
    }

    function _auction(
        bytes32 makerPositionKey,
        uint256 makerPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB,
        uint64 startTime,
        uint64 endTime
    ) internal view returns (DerivativeTypes.AmmAuction memory auction) {
        auction.makerPositionKey = makerPositionKey;
        auction.makerPositionId = makerPositionId;
        auction.poolIdA = poolIdA;
        auction.poolIdB = poolIdB;
        auction.tokenA = address(tokenA);
        auction.tokenB = address(tokenB);
        auction.reserveA = reserveA;
        auction.reserveB = reserveB;
        auction.initialReserveA = reserveA;
        auction.initialReserveB = reserveB;
        auction.invariant = reserveA * reserveB;
        auction.startTime = startTime;
        auction.endTime = endTime;
        auction.feeBps = 0;
        auction.feeAsset = DerivativeTypes.FeeAsset.TokenIn;
        auction.invariantMode = DerivativeTypes.InvariantMode.Volatile;
        auction.active = true;
        auction.finalized = false;
        auction.tokenADecimals = 18;
        auction.tokenBDecimals = 18;
    }
}

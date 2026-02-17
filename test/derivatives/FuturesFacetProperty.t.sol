// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {
    FuturesFacet,
    Futures_GracePeriodNotElapsed,
    Futures_NotReclaimed
} from "../../src/derivatives/FuturesFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Feature: position-nft-derivatives, Property 16: Grace Period Enforcement
/// @notice Validates: Requirements 11.1, 11.4
contract FuturesFacetPropertyTest is Test {
    FuturesHarness internal harness;
    PositionNFT internal nft;
    FuturesToken internal futuresToken;
    MockERC20 internal underlying;
    MockERC20 internal quote;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);

    function setUp() public {
        harness = new FuturesHarness();
        vm.warp(1);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));
        futuresToken = new FuturesToken("", address(this), address(harness));
        harness.setFuturesTokenHarness(address(futuresToken));
        harness.setEuropeanTolerance(100);
        harness.setGracePeriod(2 days);

        underlying = new MockERC20("Underlying", "UND", 18, 0);
        quote = new MockERC20("Quote", "QTE", 6, 0);
    }

    function testProperty_GracePeriodEnforcement() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 1e18;
        uint256 forwardPrice = 2e18;
        uint256 requiredQuote = _quoteAmount(totalSize, forwardPrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(quote), positionKey, requiredQuote + 1e6, requiredQuote + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 1 days);
        DerivativeTypes.CreateFuturesSeriesParams memory params = DerivativeTypes.CreateFuturesSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            quotePoolId: 2,
            forwardPrice: forwardPrice,
            expiry: expiry,
            totalSize: totalSize,
            isEuropean: false,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(params);
        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, totalSize / 2, "");
        uint256 holderBalanceBefore = futuresToken.balanceOf(holder, seriesId);
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(Futures_NotReclaimed.selector, seriesId));
        harness.burnReclaimedFuturesClaims(holder, seriesId, 1);
        uint64 graceUnlockTime = harness.getGraceUnlockTime(seriesId);

        vm.warp(graceUnlockTime - 1);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Futures_GracePeriodNotElapsed.selector, seriesId));
        harness.reclaimFutures(seriesId);

        vm.warp(graceUnlockTime);
        vm.prank(maker);
        harness.reclaimFutures(seriesId);

        assertEq(futuresToken.balanceOf(holder, seriesId), holderBalanceBefore, "holder claims remain outstanding");
        assertEq(futuresToken.balanceOf(maker, seriesId), totalSize / 2, "maker claims remain outstanding");
        assertEq(harness.getLocked(positionKey, 1), 0, "collateral unlocked");
        DerivativeTypes.FuturesSeries memory series = harness.getFuturesSeries(seriesId);
        assertEq(series.remaining, 0, "series marked fully reclaimed");
        assertTrue(series.reclaimed, "series reclaimed");

        vm.prank(address(0xCAFE));
        harness.burnReclaimedFuturesClaims(holder, seriesId, holderBalanceBefore / 2);
        assertEq(futuresToken.balanceOf(holder, seriesId), holderBalanceBefore / 2, "post-reclaim claims burnable");
    }

    /// @notice Property: Principal conservation on settlement
    /// @notice Validates: Requirements 7.2, 7.3, 10.2, 10.3
    function testProperty_PrincipalConservationOnSettlement() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 2e18;
        uint256 settleAmount = 1e18;
        uint256 forwardPrice = 2e18;
        uint256 requiredQuote = _quoteAmount(totalSize, forwardPrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(quote), positionKey, requiredQuote + 1e6, requiredQuote + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 7 days);
        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: forwardPrice,
                expiry: expiry,
                totalSize: totalSize,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, settleAmount, "");

        uint256 quoteAmount = _quoteAmount(settleAmount, forwardPrice);
        quote.mint(holder, quoteAmount);
        vm.prank(holder);
        quote.approve(address(harness), quoteAmount);

        uint256 makerUnderlyingBefore = harness.getPrincipal(positionKey, 1);
        uint256 makerQuoteBefore = harness.getPrincipal(positionKey, 2);

        uint256 payment = harness.previewSettlePayment(seriesId, settleAmount);


        vm.prank(holder);


        harness.settleFutures(seriesId, settleAmount, holder, payment, 0);

        assertEq(
            harness.getPrincipal(positionKey, 1),
            makerUnderlyingBefore - settleAmount,
            "underlying principal decreases by settled amount"
        );
        assertEq(
            harness.getPrincipal(positionKey, 2),
            makerQuoteBefore + quoteAmount,
            "quote principal increases by forward payment"
        );
        assertEq(harness.getLocked(positionKey, 1), totalSize - settleAmount, "locked collateral reduced");
        assertEq(underlying.balanceOf(holder), settleAmount, "holder receives underlying");
        assertEq(quote.balanceOf(holder), 0, "holder pays quote amount");
    }

    function test_settleFutures_refundsExcessAndCreditsOnlyRequiredPayment() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 1e18;
        uint256 forwardPrice = 2e18;
        uint256 requiredQuote = _quoteAmount(totalSize, forwardPrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(quote), positionKey, requiredQuote + 1e6, requiredQuote + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: forwardPrice,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: totalSize,
                isEuropean: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, totalSize, "");

        uint256 payment = harness.previewSettlePayment(seriesId, totalSize);
        uint256 maxPayment = payment + 1e17;
        quote.mint(holder, maxPayment);
        vm.prank(holder);
        quote.approve(address(harness), maxPayment);

        uint256 holderQuoteBefore = quote.balanceOf(holder);
        uint256 makerQuoteBefore = harness.getPrincipal(positionKey, 2);

        vm.warp(block.timestamp + 1 days);
        vm.prank(holder);
        harness.settleFutures(seriesId, totalSize, holder, maxPayment, 0);

        assertEq(holderQuoteBefore - quote.balanceOf(holder), payment, "holder pays required amount only");
        assertEq(harness.getPrincipal(positionKey, 2) - makerQuoteBefore, payment, "maker receives required amount only");
    }

    function _quoteAmount(uint256 amount, uint256 forwardPrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(underlying.decimals());
        uint256 quoteScale = 10 ** uint256(quote.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, forwardPrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, quoteScale, 1e18);
    }
}

contract FuturesHarness is FuturesFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setFuturesTokenHarness(address token) external {
        LibDerivativeStorage.derivativeStorage().futuresToken = token;
    }

    function setEuropeanTolerance(uint64 tolerance) external {
        LibDerivativeStorage.derivativeStorage().config.europeanToleranceSeconds = tolerance;
    }

    function setGracePeriod(uint64 gracePeriod) external {
        LibDerivativeStorage.derivativeStorage().config.defaultGracePeriodSeconds = gracePeriod;
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
            p.activeCreditIndex = LibFeeIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getPrincipal(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

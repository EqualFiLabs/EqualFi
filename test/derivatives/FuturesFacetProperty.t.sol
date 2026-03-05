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
            contractSize: 1,
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
                contractSize: 1,
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
                contractSize: 1,
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
        assertEq(
            harness.getPrincipal(positionKey, 2) - makerQuoteBefore, payment, "maker receives required amount only"
        );
    }

    function test_createFuturesSeries_supportsNativeUnderlyingFlatFee() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 5e18;
        uint256 flatFee = 2e16; // 0.02 native
        vm.deal(address(harness), principal);
        harness.seedPool(1, address(0), positionKey, principal, principal);
        harness.seedPool(2, address(quote), positionKey, principal, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
        harness.setFeeSplits(0, 0);
        harness.setDefaultCreateFeeConfig(0, uint128(flatFee));

        uint256 principalBefore = harness.getPrincipal(positionKey, 1);
        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                contractSize: 1,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertGt(seriesId, 0, "series created");
        assertEq(harness.getPrincipal(positionKey, 1), principalBefore - flatFee, "native flat fee applied");
    }

    function test_createFuturesSeries_usesPoolCreateFeeOverride() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 5e18;
        uint256 globalFlatFee = 1e16;
        uint256 poolOverrideFlatFee = 3e16;
        vm.deal(address(harness), principal);
        harness.seedPool(1, address(0), positionKey, principal, principal);
        harness.seedPool(2, address(quote), positionKey, principal, 0);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
        harness.setFeeSplits(0, 0);
        harness.setCreateFeeConfig(0, 10_000, 10_000, uint128(globalFlatFee), uint128(globalFlatFee));
        harness.setPoolCreateFeeOverride(1, true, 0, 10_000, 10_000, uint128(poolOverrideFlatFee), uint128(poolOverrideFlatFee));

        uint256 principalBefore = harness.getPrincipal(positionKey, 1);
        vm.prank(maker);
        harness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                contractSize: 1,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertEq(harness.getPrincipal(positionKey, 1), principalBefore - poolOverrideFlatFee, "pool override flat fee applied");
    }

    function test_createFuturesSeries_supportsFractionalNotionalPerContract() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalContracts = 20;
        uint256 contractSize = 5e15; // 0.005 underlying per futures token.
        uint256 underlyingNotional = totalContracts * contractSize;
        uint256 forwardPrice = 2e18;
        uint256 requiredQuote = _quoteAmount(underlyingNotional, forwardPrice);

        harness.seedPool(1, address(underlying), positionKey, underlyingNotional + 1e6, underlyingNotional + 1e6);
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
                totalSize: totalContracts,
                contractSize: contractSize,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        DerivativeTypes.FuturesSeries memory series = harness.getFuturesSeries(seriesId);
        assertEq(series.totalSize, totalContracts, "contract supply recorded");
        assertEq(series.remaining, totalContracts, "remaining tracks contract units");
        assertEq(harness.getFuturesContractSize(seriesId), contractSize, "contract size recorded");
        assertEq(futuresToken.balanceOf(maker, seriesId), totalContracts, "minted contract-count claim supply");
        assertEq(harness.getLocked(positionKey, 1), underlyingNotional, "underlying collateral locks full notional");

        uint256 settleContracts = 4;
        uint256 settledNotional = settleContracts * contractSize;
        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, settleContracts, "");

        uint256 payment = harness.previewSettlePayment(seriesId, settleContracts);
        assertEq(payment, _quoteAmount(settledNotional, forwardPrice), "payment scales by contract size");
        quote.mint(holder, payment);
        vm.prank(holder);
        quote.approve(address(harness), payment);

        vm.prank(holder);
        harness.settleFutures(seriesId, settleContracts, holder, payment, 0);

        DerivativeTypes.FuturesSeries memory afterSettle = harness.getFuturesSeries(seriesId);
        assertEq(afterSettle.remaining, totalContracts - settleContracts, "remaining decremented by contracts");
        assertEq(
            harness.getLocked(positionKey, 1),
            (totalContracts - settleContracts) * contractSize,
            "locked notional decremented"
        );
        assertEq(underlying.balanceOf(holder), settledNotional, "holder receives sized underlying");
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

    function setDefaultCreateFeeConfig(uint16 feeBps, uint128 flatFee) external {
        setCreateFeeConfig(feeBps, 10_000, 10_000, flatFee, flatFee);
    }

    function setCreateFeeConfig(
        uint16 defaultFeeBps,
        uint16 maxFeeBps,
        uint16 maxTotalFeeBps,
        uint128 defaultFlatFee,
        uint128 maxFlatFee
    ) public {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        ds.config.createFeeConfig.defaultFeeBps = defaultFeeBps;
        ds.config.createFeeConfig.maxFeeBps = maxFeeBps;
        ds.config.createFeeConfig.maxTotalFeeBps = maxTotalFeeBps;
        ds.config.createFeeConfig.defaultFlatFee = defaultFlatFee;
        ds.config.createFeeConfig.maxFlatFee = maxFlatFee;
    }

    function setPoolCreateFeeOverride(
        uint256 poolId,
        bool enabled,
        uint16 defaultFeeBps,
        uint16 maxFeeBps,
        uint16 maxTotalFeeBps,
        uint128 defaultFlatFee,
        uint128 maxFlatFee
    ) external {
        DerivativeTypes.DerivativeActionFeeOverride storage overrideCfg =
            LibDerivativeStorage.derivativeStorage().actionFeeOverridesByPool[poolId][uint8(DerivativeTypes.DerivativeFeeAction.Create)];
        overrideCfg.enabled = enabled;
        overrideCfg.feeConfig.defaultFeeBps = defaultFeeBps;
        overrideCfg.feeConfig.maxFeeBps = maxFeeBps;
        overrideCfg.feeConfig.maxTotalFeeBps = maxTotalFeeBps;
        overrideCfg.feeConfig.defaultFlatFee = defaultFlatFee;
        overrideCfg.feeConfig.maxFlatFee = maxFlatFee;
    }

    function setFeeSplits(uint16 treasuryBps, uint16 activeCreditBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = treasuryBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = activeCreditBps;
        store.activeCreditShareConfigured = true;
    }

    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked)
        external
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            if (underlying == address(0)) {
                LibAppStorage.s().nativeTrackedTotal += tracked;
            } else {
                MockERC20(underlying).mint(address(this), tracked);
            }
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

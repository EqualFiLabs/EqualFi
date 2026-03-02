// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {IlmTypes, IlmNotLiquidatable, IlmInvalidRiskParams, IlmUnauthorized} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledLiquidationFacet} from "../../src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol";
import {IIlmOracleAdapter} from "../../src/ilm-pooled/interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../../src/ilm-pooled/interfaces/IIlmSentinelAdapter.sol";

contract MockIlmOracleAdapterLiq is IIlmOracleAdapter {
    uint256 internal _priceRay = 1e27;

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract MockIlmSentinelAdapterLiq is IIlmSentinelAdapter {
    bool internal _borrowAllowed = true;
    bool internal _liquidationAllowed = true;

    function setBorrowAllowed(bool allowed) external {
        _borrowAllowed = allowed;
    }

    function setLiquidationAllowed(bool allowed) external {
        _liquidationAllowed = allowed;
    }

    function isBorrowAllowed() external view returns (bool) {
        return _borrowAllowed;
    }

    function isLiquidationAllowed() external view returns (bool) {
        return _liquidationAllowed;
    }
}

contract ILMPooledLiquidationHarness is ILMPooledLiquidationFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setMarketRaw(uint256 marketId, IlmTypes.IlmMarket calldata market, uint256 moduleId) external {
        LibIlmStorage.s().markets[marketId] = market;
        LibIlmStorage.s().marketModuleId[marketId] = moduleId;
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = false;
        ms.modules[moduleId].inactive = false;
    }

    function setPositionRaw(
        uint256 marketId,
        bytes32 positionKey,
        uint256 scaledSupply,
        uint256 scaledDebt,
        bool useAsCollateral
    ) external {
        LibIlmStorage.s().positions[marketId][positionKey] =
            IlmTypes.IlmPosition({scaledSupply: scaledSupply, scaledDebt: scaledDebt, useAsCollateral: useAsCollateral});
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function setPoolTotalDeposits(uint256 poolId, uint256 totalDeposits) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].totalDeposits = totalDeposits;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function setSentinelAdapterRaw(address sentinel) external {
        LibIlmStorage.s().sentinelAdapter = sentinel;
    }

    function setOracleAdapterRaw(address oracle) external {
        LibIlmStorage.s().oracleAdapter = oracle;
    }

    function setGlobalFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) {
            revert();
        }
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.treasuryShareConfigured = true;
        app.treasuryShareBps = uint16(treasuryBps);
        app.activeCreditShareConfigured = true;
        app.activeCreditShareBps = uint16(activeCreditBps);
    }

    function setModuleAciPausedRaw(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function encumberForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function seedActiveCreditEncumbrance(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibActiveCreditIndex.applyEncumbranceIncrease(LibAppStorage.s().pools[poolId], poolId, positionKey, amount);
    }

    function setMarketProtocolFeeAssets(uint256 marketId, uint256 feeAssets) external {
        LibIlmStorage.s().marketProtocolFeeAssets[marketId] = feeAssets;
    }

    function getMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketProtocolFeeAssets[marketId];
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }

    function getPosition(uint256 marketId, bytes32 positionKey) external view returns (IlmTypes.IlmPosition memory) {
        return LibIlmStorage.s().positions[marketId][positionKey];
    }

    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function getPoolTotalDeposits(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].totalDeposits;
    }

    function getPoolFeeIndex(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].feeIndex;
    }

    function getPoolActiveCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }
}

contract ILMLiquidationPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant BORROWER = address(0xB0B0);
    address internal constant LIQUIDATOR = address(0xA11CE);
    address internal constant RANDOM = address(0xBAD);

    ILMPooledLiquidationHarness internal h;
    MockIlmOracleAdapterLiq internal oracle;
    MockIlmSentinelAdapterLiq internal sentinel;
    PositionNFT internal nft;

    uint256 internal borrowerPositionId;
    bytes32 internal borrowerKey;
    uint256 internal liquidatorPositionId;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMPooledLiquidationHarness();
        oracle = new MockIlmOracleAdapterLiq();
        sentinel = new MockIlmSentinelAdapterLiq();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        vm.warp(1_000_000);

        h.setPositionNftRaw(address(nft), true);
        h.setOracleAdapterRaw(address(oracle));
        h.setSentinelAdapterRaw(address(sentinel));
        h.setGlobalFeeSplits(0, 0);

        borrowerPositionId = nft.mint(BORROWER, LOAN_POOL_ID);
        liquidatorPositionId = nft.mint(LIQUIDATOR, LOAN_POOL_ID);
        borrowerKey = nft.getPositionKey(borrowerPositionId);
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);
    }

    function _baseMarket(
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) internal view returns (IlmTypes.IlmMarket memory market) {
        market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            liquidationProtocolFeeBps: liquidationProtocolFeeBps,
            reserveFactorBps: 1_000,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: type(uint256).max,
            borrowCap: type(uint256).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 0,
            badDebt: 0
        });
    }

    function _configureCore(
        uint256 debt,
        uint256 collateral,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) internal {
        IlmTypes.IlmMarket memory market =
            _baseMarket(liquidationThresholdBps, liquidationBonusBps, liquidationProtocolFeeBps);
        market.scaledVariableDebtTotal = debt;
        market.availableLiquidity = 0;

        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, borrowerKey, 0, debt, true);
        h.setPositionRaw(MARKET_ID, liquidatorKey, 0, 0, true);

        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, debt * 2 + 100);
        h.setPoolTotalDeposits(LOAN_POOL_ID, debt * 2 + 100);
        h.setPoolTrackedBalance(LOAN_POOL_ID, debt * 4 + 1e18);

        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, collateral);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 0);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, collateral + 1e6);
        h.setPoolTrackedBalance(COLLATERAL_POOL_ID, collateral + 1e18);

        h.encumberForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, collateral);
        h.seedActiveCreditEncumbrance(borrowerKey, COLLATERAL_POOL_ID, collateral);
    }

    /// @dev Property 17: Healthy Position Liquidation Rejection.
    function test_property17_healthyPositionLiquidationRejection() public {
        _configureCore(100, 200, 9_000, 500, 100);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IlmNotLiquidatable.selector, 18e17));
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 50);
    }

    /// @dev Property 20 + 34 + revenue conservation checks.
    function testFuzz_property20_liquidationSettlementStateConsistency(
        uint128 debtRaw,
        uint128 collateralRaw,
        uint128 debtToCoverRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 10, 1e24);
        uint256 collateral = bound(uint256(collateralRaw), debt / 10 + 1, debt);
        uint256 debtToCover = bound(uint256(debtToCoverRaw), 1, debt);
        uint256 maxDebtByCollateral = (collateral * 10_000) / 10_500;
        uint256 cappedDebt = debtToCover;
        if (cappedDebt > maxDebtByCollateral) cappedDebt = maxDebtByCollateral;
        if (cappedDebt > debt) cappedDebt = debt;
        uint256 grossForAssume = (cappedDebt * 10_500) / 10_000;
        uint256 remainingCollateral = collateral - grossForAssume;
        uint256 remainingDebt = debt - cappedDebt;
        vm.assume(remainingCollateral > 0);
        vm.assume(remainingCollateral != 1);
        vm.assume(!(remainingDebt == 1 && remainingCollateral > 0));

        _configureCore(debt, collateral, 8_000, 500, 100);

        uint256 borrowerDebtBefore = h.getPosition(MARKET_ID, borrowerKey).scaledDebt;
        uint256 marketDebtBefore = h.getMarket(MARKET_ID).scaledVariableDebtTotal;
        uint256 availableLiquidityBefore = h.getMarket(MARKET_ID).availableLiquidity;
        uint256 liquidatorLoanPrincipalBefore = h.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey);
        uint256 borrowerCollateralPrincipalBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 liquidatorCollateralPrincipalBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);
        uint256 collateralEncBefore = h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID);
        uint256 activeCreditBefore = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        uint256 collateralFeeIndexBefore = h.getPoolFeeIndex(COLLATERAL_POOL_ID);
        uint256 collateralDepositsBefore = h.getPoolTotalDeposits(COLLATERAL_POOL_ID);

        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated, uint256 collateralSeizedNet) =
            h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, debtToCover);

        uint256 borrowerDebtAfter = h.getPosition(MARKET_ID, borrowerKey).scaledDebt;
        uint256 marketDebtAfter = h.getMarket(MARKET_ID).scaledVariableDebtTotal;
        uint256 availableLiquidityAfter = h.getMarket(MARKET_ID).availableLiquidity;
        uint256 liquidatorLoanPrincipalAfter = h.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey);
        uint256 borrowerCollateralPrincipalAfter = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 liquidatorCollateralPrincipalAfter = h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);
        uint256 collateralEncAfter = h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID);
        uint256 activeCreditAfter = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        uint256 collateralFeeIndexAfter = h.getPoolFeeIndex(COLLATERAL_POOL_ID);
        uint256 collateralDepositsAfter = h.getPoolTotalDeposits(COLLATERAL_POOL_ID);

        uint256 grossSeized = borrowerCollateralPrincipalBefore - borrowerCollateralPrincipalAfter;
        uint256 netCredited = liquidatorCollateralPrincipalAfter - liquidatorCollateralPrincipalBefore;
        uint256 protocolFeeCollateral = grossSeized - netCredited;

        assertEq(borrowerDebtBefore - borrowerDebtAfter, debtLiquidated);
        assertEq(marketDebtBefore - marketDebtAfter, debtLiquidated);
        assertEq(availableLiquidityAfter - availableLiquidityBefore, debtLiquidated);
        assertEq(liquidatorLoanPrincipalBefore - liquidatorLoanPrincipalAfter, debtLiquidated);

        assertEq(collateralEncBefore - collateralEncAfter, grossSeized);
        assertEq(activeCreditBefore - activeCreditAfter, grossSeized);
        assertEq(collateralSeizedNet, netCredited);
        assertEq(grossSeized, netCredited + protocolFeeCollateral);
        assertEq(collateralDepositsBefore - collateralDepositsAfter, protocolFeeCollateral);
        if (protocolFeeCollateral > 0) {
            assertGe(collateralFeeIndexAfter, collateralFeeIndexBefore);
        }
    }

    /// @dev Property 21: Bad Debt Recording.
    function test_property21_badDebtRecording() public {
        _configureCore(100, 40, 5_000, 0, 0);

        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated, uint256 seizedNet) =
            h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 100);

        IlmTypes.IlmMarket memory marketAfter = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory borrowerAfter = h.getPosition(MARKET_ID, borrowerKey);

        assertEq(debtLiquidated, 40);
        assertEq(seizedNet, 40);
        assertEq(marketAfter.badDebt, 60);
        assertEq(marketAfter.scaledVariableDebtTotal, 0);
        assertEq(borrowerAfter.scaledDebt, 0);
        assertEq(h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID), 0);
    }

    /// @dev Property 22: Dust Prevention Invariant.
    function test_property22_dustPreventionInvariant() public {
        _configureCore(3, 3, 9_000, 0, 0);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IlmInvalidRiskParams.selector);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 2);
    }

    /// @dev Property 23: Deferred claim realization and zero-debt clear on liquidation path.
    function testFuzz_property23_deferredClaimRealizationAndZeroDebtClear(
        uint128 debtRaw,
        uint128 claimRaw,
        uint128 debtToCoverRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 2, 1e24);
        uint256 claim = bound(uint256(claimRaw), 1, debt);
        uint256 debtToCover = bound(uint256(debtToCoverRaw), 1, debt);
        vm.assume(debtToCover != debt - 1);

        _configureCore(debt, debt, 5_000, 0, 0);
        h.setMarketProtocolFeeAssets(MARKET_ID, claim);
        uint256 feeIndexBefore = h.getPoolFeeIndex(LOAN_POOL_ID);

        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated,) =
            h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, debtToCover);

        uint256 claimAfter = h.getMarketProtocolFeeAssets(MARKET_ID);
        uint256 expectedRealized = claim * debtLiquidated / debt;
        uint256 expectedClaimAfter = debtLiquidated == debt ? 0 : (claim - expectedRealized);

        assertEq(claimAfter, expectedClaimAfter);
        assertGe(h.getPoolFeeIndex(LOAN_POOL_ID), feeIndexBefore);
    }

    /// @dev Property 34: Active Credit decrease on liquidation is unaffected by moduleAciPaused.
    function test_property34_activeCreditDecreaseAlwaysOn() public {
        _configureCore(100, 100, 8_000, 0, 0);
        h.setModuleAciPausedRaw(true);

        uint256 aciBefore = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        uint256 collateralPrincipalBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);

        vm.prank(LIQUIDATOR);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 40);

        uint256 collateralPrincipalAfter = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 grossSeized = collateralPrincipalBefore - collateralPrincipalAfter;
        uint256 aciAfter = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        assertEq(aciBefore - aciAfter, grossSeized);
    }

    /// @dev Property 35: Liquidator-only authorization in liquidation.
    function test_property35_liquidatorOnlyAuthorizationInLiquidation() public {
        _configureCore(100, 100, 8_000, 0, 0);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 10);

        vm.prank(LIQUIDATOR);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 10);
    }
}

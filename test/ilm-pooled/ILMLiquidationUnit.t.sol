// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {IlmTypes, IlmInvalidRiskParams, IlmSentinelBlocked} from "../../src/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {ILMPooledLiquidationFacet} from "../../src/modules/ILMPooledLiquidationFacet.sol";
import {IIlmOracleAdapter} from "../../src/interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../../src/interfaces/IIlmSentinelAdapter.sol";

contract MockIlmOracleAdapterLiqUnit is IIlmOracleAdapter {
    uint256 internal _priceRay = 1e27;

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract MockIlmSentinelAdapterLiqUnit is IIlmSentinelAdapter {
    bool internal _borrowAllowed = true;
    bool internal _liquidationAllowed = true;

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

contract ILMPooledLiquidationHarnessUnit is ILMPooledLiquidationFacet {
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

    function encumberForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function seedActiveCreditEncumbrance(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibActiveCreditIndex.applyEncumbranceIncrease(LibAppStorage.s().pools[poolId], poolId, positionKey, amount);
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

    function getPoolActiveCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }
}

contract ILMLiquidationUnitTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant BORROWER = address(0xB0B0);
    address internal constant LIQUIDATOR = address(0xA11CE);

    ILMPooledLiquidationHarnessUnit internal h;
    MockIlmOracleAdapterLiqUnit internal oracle;
    MockIlmSentinelAdapterLiqUnit internal sentinel;
    PositionNFT internal nft;

    uint256 internal borrowerPositionId;
    bytes32 internal borrowerKey;
    uint256 internal liquidatorPositionId;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMPooledLiquidationHarnessUnit();
        oracle = new MockIlmOracleAdapterLiqUnit();
        sentinel = new MockIlmSentinelAdapterLiqUnit();
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

    function _market(uint16 ltBps, uint16 bonusBps, uint16 feeBps, uint256 debt) internal view returns (IlmTypes.IlmMarket memory m) {
        m = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: ltBps,
            liquidationBonusBps: bonusBps,
            liquidationProtocolFeeBps: feeBps,
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
            scaledVariableDebtTotal: debt,
            availableLiquidity: 0,
            badDebt: 0
        });
    }

    function _configure(uint16 ltBps, uint16 bonusBps, uint16 feeBps, uint256 debt, uint256 collateral) internal {
        h.setMarketRaw(MARKET_ID, _market(ltBps, bonusBps, feeBps, debt), MODULE_ID);
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

    function test_unit_closeFactorBoundary_usesDefault50At95OrAbove() public {
        _configure(9_600, 0, 0, 100, 100); // HF = 0.96
        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated,) =
            h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 100);
        assertEq(debtLiquidated, 50);
    }

    function test_unit_closeFactorBoundary_usesFull100Below95() public {
        _configure(9_400, 0, 0, 100, 100); // HF = 0.94
        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated,) =
            h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 100);
        assertEq(debtLiquidated, 100);
    }

    function test_unit_fullCollateralExhaustionRecordsBadDebt() public {
        _configure(5_000, 0, 0, 100, 40);

        vm.prank(LIQUIDATOR);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 100);

        IlmTypes.IlmMarket memory marketAfter = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory borrowerAfter = h.getPosition(MARKET_ID, borrowerKey);
        assertEq(marketAfter.badDebt, 60);
        assertEq(marketAfter.scaledVariableDebtTotal, 0);
        assertEq(borrowerAfter.scaledDebt, 0);
    }

    function test_unit_dustThresholdEnforced() public {
        _configure(9_000, 0, 0, 3, 3);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IlmInvalidRiskParams.selector);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 2);
    }

    function test_unit_sentinelBlocking() public {
        _configure(8_000, 0, 0, 100, 100);
        sentinel.setLiquidationAllowed(false);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IlmSentinelBlocked.selector);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 10);
    }

    function test_unit_revenueSplitAndAciConservation() public {
        _configure(6_000, 500, 200, 100, 150);

        uint256 borrowerCollateralBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 liquidatorCollateralBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);
        uint256 aciBefore = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        uint256 depositsBefore = h.getPoolTotalDeposits(COLLATERAL_POOL_ID);

        vm.prank(LIQUIDATOR);
        h.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 50);

        uint256 borrowerCollateralAfter = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 liquidatorCollateralAfter = h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);
        uint256 aciAfter = h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID);
        uint256 depositsAfter = h.getPoolTotalDeposits(COLLATERAL_POOL_ID);

        uint256 gross = borrowerCollateralBefore - borrowerCollateralAfter;
        uint256 net = liquidatorCollateralAfter - liquidatorCollateralBefore;
        uint256 fee = gross - net;

        assertEq(gross, net + fee);
        assertEq(aciBefore - aciAfter, gross);
        assertEq(depositsBefore - depositsAfter, fee);
    }
}

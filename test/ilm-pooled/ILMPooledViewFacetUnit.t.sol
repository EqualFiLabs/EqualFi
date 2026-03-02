// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {IlmTypes, IlmMarketNotFound} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../../src/ilm-pooled/libraries/LibIlmIndexing.sol";
import {LibIlmInterestRate} from "../../src/ilm-pooled/libraries/LibIlmInterestRate.sol";
import {ILMPooledViewFacet} from "../../src/ilm-pooled/facets/ILMPooledViewFacet.sol";
import {IIlmOracleAdapter} from "../../src/ilm-pooled/interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../../src/ilm-pooled/interfaces/IIlmSentinelAdapter.sol";

contract MockIlmOracleAdapterView is IIlmOracleAdapter {
    uint256 internal _priceRay = 1e27;

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract MockIlmSentinelAdapterView is IIlmSentinelAdapter {
    bool internal _borrowAllowed = true;
    bool internal _liquidationAllowed = true;

    function isBorrowAllowed() external view returns (bool) {
        return _borrowAllowed;
    }

    function isLiquidationAllowed() external view returns (bool) {
        return _liquidationAllowed;
    }
}

contract ILMPooledViewFacetHarness is ILMPooledViewFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setModuleStateRaw(uint256 moduleId, bool paused, bool inactive) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = paused;
        ms.modules[moduleId].inactive = inactive;
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

    function setSentinelAdapterRaw(address sentinel) external {
        LibIlmStorage.s().sentinelAdapter = sentinel;
    }

    function setOracleAdapterRaw(address oracle) external {
        LibIlmStorage.s().oracleAdapter = oracle;
    }

    function setMarketProtocolFeeAssets(uint256 marketId, uint256 feeAssets) external {
        LibIlmStorage.s().marketProtocolFeeAssets[marketId] = feeAssets;
    }

    function encumberForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }
}

contract ILMPooledViewFacetUnitTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant OWNER = address(0xA11CE);

    ILMPooledViewFacetHarness internal h;
    MockIlmOracleAdapterView internal oracle;
    MockIlmSentinelAdapterView internal sentinel;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledViewFacetHarness();
        oracle = new MockIlmOracleAdapterView();
        sentinel = new MockIlmSentinelAdapterView();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        vm.warp(1_000_000);

        h.setPositionNftRaw(address(nft), true);
        h.setOracleAdapterRaw(address(oracle));
        h.setSentinelAdapterRaw(address(sentinel));
        h.setGlobalFeeSplits(0, 0);

        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    function _market(uint64 lastUpdate) internal pure returns (IlmTypes.IlmMarket memory market) {
        market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
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
            lastUpdate: lastUpdate,
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 0,
            badDebt: 0
        });
    }

    function test_getPooledMarket_roundTrip() public {
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp));
        market.scaledSupplyTotal = 123;
        market.availableLiquidity = 999;
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);

        IlmTypes.IlmMarket memory got = h.getPooledMarket(MARKET_ID);
        assertEq(got.loanPoolId, market.loanPoolId);
        assertEq(got.collateralPoolId, market.collateralPoolId);
        assertEq(got.availableLiquidity, market.availableLiquidity);
        assertEq(got.scaledSupplyTotal, market.scaledSupplyTotal);
    }

    function test_getPooledPosition_roundTrip() public {
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp));
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 77, 55, true);

        IlmTypes.IlmPosition memory got = h.getPooledPosition(MARKET_ID, positionId);
        assertEq(got.scaledSupply, 77);
        assertEq(got.scaledDebt, 55);
        assertTrue(got.useAsCollateral);
    }

    function test_previewBalances_afterStateTransitions() public {
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp));
        market.scaledSupplyTotal = 1_000;
        market.scaledVariableDebtTotal = 150;
        market.availableLiquidity = 850;
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 1_000, 150, true);

        IlmTypes.IlmMarket memory gotMarket = h.getPooledMarket(MARKET_ID);
        IlmTypes.IlmPosition memory gotPosition = h.getPooledPosition(MARKET_ID, positionId);

        uint256 expectedSupply =
            LibIlmIndexing.fromScaledSupply(gotPosition.scaledSupply, gotMarket.liquidityIndexRay);
        uint256 expectedDebt =
            LibIlmIndexing.fromScaledDebt(gotPosition.scaledDebt, gotMarket.variableBorrowIndexRay);

        assertEq(h.previewSupplyBalance(MARKET_ID, positionId), expectedSupply);
        assertEq(h.previewDebtBalance(MARKET_ID, positionId), expectedDebt);
    }

    function test_previewHealthFactor_usesSupplyAndExternalCollateral() public {
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp));
        market.scaledVariableDebtTotal = 400;
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 500, 400, true);
        h.encumberForModule(positionKey, COLLATERAL_POOL_ID, MODULE_ID, 100);
        oracle.setPriceRay(2e27);

        uint256 hf = h.previewHealthFactor(MARKET_ID, positionId);
        assertEq(hf, 14e17); // 1.4e18
    }

    function test_previewBalances_includeElapsedIndexAccrual() public {
        uint256 elapsed = 7 days;
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp - elapsed));
        market.scaledSupplyTotal = 1_000;
        market.scaledVariableDebtTotal = 500;
        market.availableLiquidity = 500;
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 1_000, 500, true);

        (uint256 expectedLiqIndex, uint256 expectedBorrowIndex) = _expectedPreviewIndexes(market, elapsed);
        uint256 expectedSupply = LibIlmIndexing.fromScaledSupply(1_000, expectedLiqIndex);
        uint256 expectedDebt = LibIlmIndexing.fromScaledDebt(500, expectedBorrowIndex);

        assertEq(h.previewSupplyBalance(MARKET_ID, positionId), expectedSupply);
        assertEq(h.previewDebtBalance(MARKET_ID, positionId), expectedDebt);
    }

    function test_getPooledMarketProtocolFeeAssets_roundTrip() public {
        IlmTypes.IlmMarket memory market = _market(uint64(block.timestamp));
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setMarketProtocolFeeAssets(MARKET_ID, 12345);

        assertEq(h.getPooledMarketProtocolFeeAssets(MARKET_ID), 12345);
    }

    function test_views_revertForUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, MARKET_ID));
        h.getPooledMarket(MARKET_ID);

        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, MARKET_ID));
        h.getPooledPosition(MARKET_ID, positionId);

        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, MARKET_ID));
        h.previewHealthFactor(MARKET_ID, positionId);
    }

    function _expectedPreviewIndexes(IlmTypes.IlmMarket memory market, uint256 elapsed)
        internal
        pure
        returns (uint256 liquidityIndexRay, uint256 variableBorrowIndexRay)
    {
        liquidityIndexRay = market.liquidityIndexRay;
        variableBorrowIndexRay = market.variableBorrowIndexRay;

        uint256 totalDebtBefore = LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, variableBorrowIndexRay);
        uint256 utilizationRay = Math.mulDiv(totalDebtBefore, IlmTypes.RAY, totalDebtBefore + market.availableLiquidity);
        uint256 optimalUtilizationRay = Math.mulDiv(market.optimalUtilizationBps, IlmTypes.RAY, IlmTypes.BPS);

        uint256 variableBorrowRateRay = LibIlmInterestRate.computeVariableBorrowRate(
            utilizationRay,
            optimalUtilizationRay,
            market.baseVariableRateRayPerYear,
            market.variableSlope1RayPerYear,
            market.variableSlope2RayPerYear
        );
        uint256 liquidityRateRay =
            LibIlmInterestRate.computeLiquidityRate(variableBorrowRateRay, utilizationRay, market.reserveFactorBps);

        uint256 liquidityFactorRay = IlmTypes.RAY + Math.mulDiv(liquidityRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);
        uint256 variableBorrowFactorRay =
            IlmTypes.RAY + Math.mulDiv(variableBorrowRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);

        liquidityIndexRay = Math.mulDiv(liquidityIndexRay, liquidityFactorRay, IlmTypes.RAY);
        variableBorrowIndexRay = Math.mulDiv(variableBorrowIndexRay, variableBorrowFactorRay, IlmTypes.RAY);
    }
}

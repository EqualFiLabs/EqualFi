// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {
    IlmTypes,
    IlmSupplyCapExceeded,
    IlmInsufficientLiquidity
} from "../../src/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../../src/libraries/LibIlmIndexing.sol";
import {ILMPooledFacet} from "../../src/modules/ILMPooledFacet.sol";
import {ModulePausedError} from "../../src/libraries/Errors.sol";

contract ILMPooledFacetHarnessSW is ILMPooledFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function setModuleStateRaw(uint256 moduleId, bool paused, bool inactive) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = paused;
        ms.modules[moduleId].inactive = inactive;
    }

    function setModuleAciPausedRaw(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
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

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }

    function getPosition(uint256 marketId, bytes32 positionKey) external view returns (IlmTypes.IlmPosition memory) {
        return LibIlmStorage.s().positions[marketId][positionKey];
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }
}

contract ILMSupplyWithdrawPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant OWNER = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);

    ILMPooledFacetHarnessSW internal h;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessSW();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    /// @dev Property 3: Supply State Consistency
    /// Validates: Requirements 2.1, 2.2, 2.4
    function testFuzz_property3_supplyStateConsistency(
        uint128 scaledSupplyTotalRaw,
        uint128 positionSupplyRaw,
        uint128 amountRaw,
        uint128 indexRaw,
        uint128 availableLiquidityRaw,
        uint128 principalBufferRaw
    ) public {
        uint256 liquidityIndexRay = bound(uint256(indexRaw), IlmTypes.RAY, 3e27);
        uint256 scaledSupplyTotal = bound(uint256(scaledSupplyTotalRaw), 1, 1e24);
        uint256 positionSupply = bound(uint256(positionSupplyRaw), 0, scaledSupplyTotal);
        uint256 amount = bound(uint256(amountRaw), 1, 1e18);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), 0, 1e18);
        uint256 principalBuffer = bound(uint256(principalBufferRaw), 0, 1e24);

        uint256 scaledMinted = LibIlmIndexing.toScaledSupply(amount, liquidityIndexRay);
        vm.assume(scaledMinted <= type(uint256).max - scaledSupplyTotal);
        vm.assume(scaledMinted <= type(uint256).max - positionSupply);

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
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
            liquidityIndexRay: uint128(liquidityIndexRay),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: scaledSupplyTotal,
            scaledVariableDebtTotal: 0,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, positionSupply, 0, false);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, amount + principalBuffer);

        vm.prank(OWNER);
        h.pooledSupply(positionId, MARKET_ID, amount);

        IlmTypes.IlmMarket memory gotMarket = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory gotPosition = h.getPosition(MARKET_ID, positionKey);
        assertEq(gotMarket.scaledSupplyTotal, scaledSupplyTotal + scaledMinted);
        assertEq(gotMarket.availableLiquidity, availableLiquidity + amount);
        assertEq(gotPosition.scaledSupply, positionSupply + scaledMinted);
        assertTrue(gotPosition.useAsCollateral);
        assertEq(h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID), amount);
    }

    /// @dev Property 5: Withdraw State Consistency
    /// Validates: Requirements 3.1, 3.3
    function testFuzz_property5_withdrawStateConsistency(
        uint128 positionSupplyRaw,
        uint128 marketSupplyTotalRaw,
        uint128 amountRaw,
        uint128 indexRaw,
        uint128 availableLiquidityRaw,
        uint128 encExtraRaw
    ) public {
        uint256 liquidityIndexRay = bound(uint256(indexRaw), IlmTypes.RAY, 3e27);
        uint256 positionSupply = bound(uint256(positionSupplyRaw), 1, 1e30);
        uint256 marketSupplyTotal = bound(uint256(marketSupplyTotalRaw), positionSupply, positionSupply + 1e30);
        uint256 maxWithdrawAssets = LibIlmIndexing.fromScaledSupply(positionSupply, liquidityIndexRay);
        vm.assume(maxWithdrawAssets > 0);
        uint256 amount = bound(uint256(amountRaw), 1, maxWithdrawAssets);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), amount, amount + 1e24);
        uint256 encExtra = bound(uint256(encExtraRaw), 0, 1e24);

        uint256 scaledBurned = LibIlmIndexing.toScaledWithdraw(amount, liquidityIndexRay);
        vm.assume(scaledBurned <= positionSupply);
        vm.assume(scaledBurned <= marketSupplyTotal);

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
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
            liquidityIndexRay: uint128(liquidityIndexRay),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: marketSupplyTotal,
            scaledVariableDebtTotal: 0,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, positionSupply, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, amount + encExtra + 1);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, amount + encExtra);

        vm.prank(OWNER);
        uint256 withdrawn = h.pooledWithdraw(positionId, MARKET_ID, amount);
        assertEq(withdrawn, amount);

        IlmTypes.IlmMarket memory gotMarket = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory gotPosition = h.getPosition(MARKET_ID, positionKey);
        assertEq(gotMarket.scaledSupplyTotal, marketSupplyTotal - scaledBurned);
        assertEq(gotMarket.availableLiquidity, availableLiquidity - amount);
        assertEq(gotPosition.scaledSupply, positionSupply - scaledBurned);
        assertEq(h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID), encExtra);
    }

    /// @dev Property 4: Cap Enforcement (supply cap portion)
    /// Validates: Requirements 2.2
    function testFuzz_property4_supplyCapEnforcement(uint128 currentAssetsRaw, uint128 amountRaw) public {
        uint256 currentAssets = bound(uint256(currentAssetsRaw), 1, 1e24);
        uint256 amount = bound(uint256(amountRaw), 1, 1e24);

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
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
            supplyCap: currentAssets + amount - 1,
            borrowCap: type(uint256).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: currentAssets,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 0,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 0, 0, false);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, amount + 1);

        uint256 expectedCap = currentAssets + amount - 1;
        uint256 expectedAttempted = currentAssets + amount;

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmSupplyCapExceeded.selector, expectedCap, expectedAttempted));
        h.pooledSupply(positionId, MARKET_ID, amount);
    }

    function test_supplyWithdraw_modulePauseGateAndAuthorization() public {
        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
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
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 1_000,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 1_000,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 1_000, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1_000);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, 900);

        vm.prank(OPERATOR);
        vm.expectRevert();
        h.pooledSupply(positionId, MARKET_ID, 1);

        h.setAuthorizationRaw(positionKey, OPERATOR, true);
        vm.prank(OPERATOR);
        h.pooledSupply(positionId, MARKET_ID, 1);

        h.setModuleStateRaw(MODULE_ID, true, false);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledWithdraw(positionId, MARKET_ID, 1);
    }

    function test_withdrawRevertsWhenInsufficientAvailableLiquidity() public {
        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
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
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 1_000,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 10,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 1_000, 0, true);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, 1_000);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1_000);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmInsufficientLiquidity.selector, 100, 10));
        h.pooledWithdraw(positionId, MARKET_ID, 100);
    }
}

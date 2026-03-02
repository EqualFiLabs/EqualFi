// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    IlmTypes,
    IlmBorrowCapExceeded,
    IlmInsufficientLiquidity,
    IlmSentinelBlocked
} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../../src/ilm-pooled/libraries/LibIlmIndexing.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {IIlmSentinelAdapter} from "../../src/ilm-pooled/interfaces/IIlmSentinelAdapter.sol";

contract MockIlmSentinelAdapterBR is IIlmSentinelAdapter {
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

contract ILMPooledFacetHarnessBR is ILMPooledFacet {
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

    function setPoolActionFee(uint256 poolId, bytes32 action, uint128 amount, bool enabled) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].actionFees[action] =
            Types.ActionFeeConfig({amount: amount, enabled: enabled});
    }

    function setGlobalFeeSplits(uint16 treasuryBps, uint16 activeCreditBps) external {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.treasuryShareConfigured = true;
        app.treasuryShareBps = treasuryBps;
        app.activeCreditShareConfigured = true;
        app.activeCreditShareBps = activeCreditBps;
    }

    function setSentinelAdapterRaw(address sentinel) external {
        LibIlmStorage.s().sentinelAdapter = sentinel;
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
}

contract ILMBorrowRepayPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant OWNER = address(0xA11CE);

    ILMPooledFacetHarnessBR internal h;
    MockIlmSentinelAdapterBR internal sentinel;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessBR();
        sentinel = new MockIlmSentinelAdapterBR();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        h.setSentinelAdapterRaw(address(sentinel));
        h.setGlobalFeeSplits(0, 0);

        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    /// @dev Property 7: Borrow State Consistency
    /// Validates: Requirements 4.1, 4.3, 4.5
    function testFuzz_property7_borrowStateConsistency(
        uint128 borrowAssetsRaw,
        uint128 availableLiquidityRaw,
        uint128 supplyScaledRaw,
        uint128 principalRaw
    ) public {
        uint256 borrowAssets = bound(uint256(borrowAssetsRaw), 1, 1e24);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), borrowAssets, borrowAssets + 1e24);
        uint256 requiredSupply = (borrowAssets * IlmTypes.BPS) / 8_000 + 1;
        uint256 supplyScaled = bound(uint256(supplyScaledRaw), requiredSupply, requiredSupply + 1e24);
        uint256 principal = bound(uint256(principalRaw), 0, 1e24);

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
            scaledSupplyTotal: supplyScaled,
            scaledVariableDebtTotal: 0,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, supplyScaled, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, principal);
        h.setPoolTotalDeposits(LOAN_POOL_ID, principal);

        uint256 expectedScaledDebt = LibIlmIndexing.toScaledDebt(borrowAssets, IlmTypes.RAY);

        vm.prank(OWNER);
        h.pooledBorrow(positionId, MARKET_ID, borrowAssets);

        IlmTypes.IlmMarket memory gotMarket = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory gotPosition = h.getPosition(MARKET_ID, positionKey);

        assertEq(gotPosition.scaledDebt, expectedScaledDebt);
        assertEq(gotMarket.scaledVariableDebtTotal, expectedScaledDebt);
        assertEq(gotMarket.availableLiquidity, availableLiquidity - borrowAssets);
        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), principal + borrowAssets);
    }

    /// @dev Property 8: Borrow Liquidity Check
    /// Validates: Requirements 4.3
    function testFuzz_property8_borrowLiquidityCheck(uint128 availableLiquidityRaw, uint128 extraRaw) public {
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), 1, 1e24);
        uint256 borrowAssets = availableLiquidity + bound(uint256(extraRaw), 1, 1e24);
        uint256 supplyScaled = (borrowAssets * IlmTypes.BPS) / 8_000 + 1;

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
            scaledSupplyTotal: supplyScaled,
            scaledVariableDebtTotal: 0,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, supplyScaled, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 0);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 0);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmInsufficientLiquidity.selector, borrowAssets, availableLiquidity));
        h.pooledBorrow(positionId, MARKET_ID, borrowAssets);
    }

    /// @dev Property 9: Repay State Consistency with Clamping
    /// Validates: Requirements 5.1, 5.2, 5.4
    function testFuzz_property9_repayStateConsistencyWithClamping(
        uint128 debtRaw,
        uint128 repayRaw,
        uint128 principalRaw,
        uint128 availableLiquidityRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 1, 1e24);
        uint256 repayRequested = bound(uint256(repayRaw), 1, 2e24);
        uint256 expectedRepaid = repayRequested < debt ? repayRequested : debt;
        uint256 principal = bound(uint256(principalRaw), expectedRepaid, expectedRepaid + 1e24);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), 0, 1e24);

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
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: debt,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 0, debt, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, principal);
        h.setPoolTotalDeposits(LOAN_POOL_ID, principal);
        h.setPoolTrackedBalance(LOAN_POOL_ID, principal + availableLiquidity + 1e24);

        vm.prank(OWNER);
        uint256 repaid = h.pooledRepay(positionId, MARKET_ID, repayRequested);
        assertEq(repaid, expectedRepaid);

        IlmTypes.IlmMarket memory gotMarket = h.getMarket(MARKET_ID);
        IlmTypes.IlmPosition memory gotPosition = h.getPosition(MARKET_ID, positionKey);
        assertEq(gotPosition.scaledDebt, debt - expectedRepaid);
        assertEq(gotMarket.scaledVariableDebtTotal, debt - expectedRepaid);
        assertEq(gotMarket.availableLiquidity, availableLiquidity + expectedRepaid);
        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), principal - expectedRepaid);
    }

    /// @dev Property 4: Cap Enforcement (borrow cap portion)
    /// Validates: Requirements 4.4
    function testFuzz_property4_borrowCapEnforcement(uint128 debtRaw, uint128 borrowRaw) public {
        uint256 debt = bound(uint256(debtRaw), 1, 1e24);
        uint256 borrowAssets = bound(uint256(borrowRaw), 1, 1e24);
        uint256 cap = debt + borrowAssets - 1;
        uint256 attempted = debt + borrowAssets;
        uint256 supplyScaled = (attempted * IlmTypes.BPS) / 8_000 + 1;

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
            borrowCap: cap,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: supplyScaled,
            scaledVariableDebtTotal: debt,
            availableLiquidity: borrowAssets,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, supplyScaled, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 0);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 0);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmBorrowCapExceeded.selector, cap, attempted));
        h.pooledBorrow(positionId, MARKET_ID, borrowAssets);
    }

    function test_borrowSentinelBlocksWhenDisabled() public {
        uint256 borrowAssets = 100;
        uint256 supplyScaled = 1_000;
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
            scaledSupplyTotal: supplyScaled,
            scaledVariableDebtTotal: 0,
            availableLiquidity: borrowAssets,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, supplyScaled, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 0);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 0);

        sentinel.setBorrowAllowed(false);
        vm.prank(OWNER);
        vm.expectRevert(IlmSentinelBlocked.selector);
        h.pooledBorrow(positionId, MARKET_ID, borrowAssets);
    }
}

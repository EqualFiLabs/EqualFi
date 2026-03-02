// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IlmTypes} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {IIlmSentinelAdapter} from "../../src/ilm-pooled/interfaces/IIlmSentinelAdapter.sol";
import {LibIlmInterestRate} from "../../src/ilm-pooled/libraries/LibIlmInterestRate.sol";

contract MockIlmSentinelAdapterRR is IIlmSentinelAdapter {
    bool internal _borrowAllowed = true;

    function setBorrowAllowed(bool allowed) external {
        _borrowAllowed = allowed;
    }

    function isBorrowAllowed() external view returns (bool) {
        return _borrowAllowed;
    }

    function isLiquidationAllowed() external pure returns (bool) {
        return true;
    }
}

contract ILMPooledFacetHarnessRR is ILMPooledFacet {
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

    function setMarketProtocolFeeAssets(uint256 marketId, uint256 feeAssets) external {
        LibIlmStorage.s().marketProtocolFeeAssets[marketId] = feeAssets;
    }

    function getMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketProtocolFeeAssets[marketId];
    }

    function getPoolFeeIndex(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].feeIndex;
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }
}

contract ILMRevenueRoutingPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant OWNER = address(0xA11CE);

    ILMPooledFacetHarnessRR internal h;
    MockIlmSentinelAdapterRR internal sentinel;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessRR();
        sentinel = new MockIlmSentinelAdapterRR();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        vm.warp(1_000_000);

        h.setPositionNftRaw(address(nft), true);
        h.setSentinelAdapterRaw(address(sentinel));
        h.setGlobalFeeSplits(0, 0);

        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    /// @dev Property 15: Deferred Interest Claim Accrual Correctness
    /// Validates: Requirements 7.7, 10.1
    function testFuzz_property15_deferredInterestClaimAccrualCorrectness(
        uint128 scaledDebtRaw,
        uint128 availableLiquidityRaw,
        uint32 elapsedRaw,
        uint16 reserveFactorBpsRaw,
        uint16 optimalUtilizationBpsRaw,
        uint32 baseVariableRateRayPerYear,
        uint32 slope1RayPerYear,
        uint32 slope2RayPerYear,
        uint128 initialClaimRaw
    ) public {
        uint256 scaledDebt = bound(uint256(scaledDebtRaw), 1, 1e24);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), 1, 1e24);
        uint256 elapsed = bound(uint256(elapsedRaw), 1, 7 days);
        uint256 reserveFactorBps = bound(uint256(reserveFactorBpsRaw), 1, IlmTypes.BPS);
        uint256 optimalUtilizationBps = bound(uint256(optimalUtilizationBpsRaw), 1, IlmTypes.BPS - 1);
        uint256 initialClaim = bound(uint256(initialClaimRaw), 0, 1e24);
        uint256 borrowAmount = 1;

        uint256 supplyScaled = (scaledDebt + borrowAmount) * IlmTypes.BPS / 8_000 + 100;
        uint256 lastUpdate = block.timestamp - elapsed;

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: uint16(reserveFactorBps),
            optimalUtilizationBps: uint16(optimalUtilizationBps),
            baseVariableRateRayPerYear: baseVariableRateRayPerYear,
            variableSlope1RayPerYear: slope1RayPerYear,
            variableSlope2RayPerYear: slope2RayPerYear,
            supplyCap: type(uint256).max,
            borrowCap: type(uint256).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(lastUpdate),
            scaledSupplyTotal: supplyScaled,
            scaledVariableDebtTotal: scaledDebt,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, supplyScaled, 0, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 0);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 1e18);
        h.setPoolTrackedBalance(LOAN_POOL_ID, type(uint128).max);
        h.setPoolActionFee(LOAN_POOL_ID, keccak256("ACTION_BORROW"), 0, false);
        h.setMarketProtocolFeeAssets(MARKET_ID, initialClaim);

        uint256 expectedAccrued = _expectedProtocolFeeAccrued(market, elapsed);

        vm.prank(OWNER);
        h.pooledBorrow(positionId, MARKET_ID, borrowAmount);

        uint256 claimAfter = h.getMarketProtocolFeeAssets(MARKET_ID);
        assertEq(claimAfter, initialClaim + expectedAccrued);
    }

    /// @dev Property 23: Deferred Claim Realization and Zero-Debt Clear
    /// Validates: Requirements 10.2, 10.4
    function testFuzz_property23_deferredClaimRealizationAndZeroDebtClear(
        uint128 debtRaw,
        uint128 claimRaw,
        uint128 repayRaw,
        uint128 principalBufferRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 1, 1e24);
        uint256 claim = bound(uint256(claimRaw), 1, debt);
        uint256 repayAmount = bound(uint256(repayRaw), 1, debt);
        uint256 principal = repayAmount + bound(uint256(principalBufferRaw), 0, 1e24);

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
            availableLiquidity: 0,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, 0, debt, true);
        h.setMarketProtocolFeeAssets(MARKET_ID, claim);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, principal);
        h.setPoolTotalDeposits(LOAN_POOL_ID, principal);
        h.setPoolTrackedBalance(LOAN_POOL_ID, principal + debt + claim + 1e24);
        h.setPoolActionFee(LOAN_POOL_ID, keccak256("ACTION_REPAY"), 0, false);

        uint256 expectedRepaid = repayAmount < debt ? repayAmount : debt;
        uint256 expectedRealized = claim * expectedRepaid / debt;
        uint256 expectedClaimAfter = expectedRepaid == debt ? 0 : (claim - expectedRealized);

        uint256 feeIndexBefore = h.getPoolFeeIndex(LOAN_POOL_ID);

        vm.prank(OWNER);
        uint256 repaid = h.pooledRepay(positionId, MARKET_ID, repayAmount);
        assertEq(repaid, expectedRepaid);

        uint256 claimAfter = h.getMarketProtocolFeeAssets(MARKET_ID);
        assertEq(claimAfter, expectedClaimAfter);

        uint256 feeIndexAfter = h.getPoolFeeIndex(LOAN_POOL_ID);
        assertGe(feeIndexAfter, feeIndexBefore);
    }

    function _expectedProtocolFeeAccrued(IlmTypes.IlmMarket memory market, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        uint256 totalDebtBefore =
            Math.mulDiv(market.scaledVariableDebtTotal, market.variableBorrowIndexRay, IlmTypes.RAY, Math.Rounding.Ceil);
        uint256 utilizationRay = Math.mulDiv(
            totalDebtBefore, IlmTypes.RAY, totalDebtBefore + market.availableLiquidity
        );
        uint256 optimalRay = Math.mulDiv(market.optimalUtilizationBps, IlmTypes.RAY, IlmTypes.BPS);

        uint256 variableBorrowRateRay = LibIlmInterestRate.computeVariableBorrowRate(
            utilizationRay,
            optimalRay,
            market.baseVariableRateRayPerYear,
            market.variableSlope1RayPerYear,
            market.variableSlope2RayPerYear
        );
        uint256 variableBorrowFactorRay =
            IlmTypes.RAY + Math.mulDiv(variableBorrowRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);
        uint256 newBorrowIndex = Math.mulDiv(market.variableBorrowIndexRay, variableBorrowFactorRay, IlmTypes.RAY);

        uint256 totalDebtAfter =
            Math.mulDiv(market.scaledVariableDebtTotal, newBorrowIndex, IlmTypes.RAY, Math.Rounding.Ceil);
        uint256 debtIncrease = totalDebtAfter - totalDebtBefore;
        return Math.mulDiv(debtIncrease, market.reserveFactorBps, IlmTypes.BPS);
    }
}

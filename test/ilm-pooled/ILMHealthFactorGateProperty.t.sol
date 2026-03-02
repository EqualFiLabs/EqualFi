// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {IlmTypes, IlmUnsafePosition} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {IIlmOracleAdapter} from "../../src/ilm-pooled/interfaces/IIlmOracleAdapter.sol";

contract MockIlmOracleAdapterHF is IIlmOracleAdapter {
    uint256 internal _priceRay;

    function setPrice(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract ILMPooledFacetHarnessHF is ILMPooledFacet {
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

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function setOracleAdapterRaw(address adapter) external {
        LibIlmStorage.s().oracleAdapter = adapter;
    }
}

contract ILMHealthFactorGatePropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    uint16 internal constant LT_BPS = 8_000;
    address internal constant OWNER = address(0xA11CE);

    ILMPooledFacetHarnessHF internal h;
    MockIlmOracleAdapterHF internal oracle;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessHF();
        oracle = new MockIlmOracleAdapterHF();
        oracle.setPrice(IlmTypes.RAY);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        h.setPositionNftRaw(address(nft), true);
        h.setOracleAdapterRaw(address(oracle));

        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    /// @dev Property 6: Health Factor Gate Enforcement (withdraw path)
    /// Validates: Requirements 3.2, 4.2
    function testFuzz_property6_withdrawHealthFactorGate(
        uint128 debtRaw,
        uint128 collateralBeforeRaw,
        uint128 withdrawRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 1, 1e24);
        uint256 requiredSafe = Math.ceilDiv(debt * IlmTypes.BPS, uint256(LT_BPS));
        uint256 collateralBefore = bound(uint256(collateralBeforeRaw), requiredSafe + 1, requiredSafe + 1e24);
        uint256 maxUnsafeAfter = requiredSafe - 1;
        uint256 collateralAfter = bound(uint256(withdrawRaw), 0, maxUnsafeAfter);
        uint256 withdrawAmount = collateralBefore - collateralAfter;

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: LT_BPS,
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
            scaledSupplyTotal: collateralBefore,
            scaledVariableDebtTotal: debt,
            availableLiquidity: collateralBefore,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, positionKey, collateralBefore, debt, true);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, collateralBefore + 1);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, collateralBefore);

        vm.prank(OWNER);
        vm.expectRevert();
        h.pooledWithdraw(positionId, MARKET_ID, withdrawAmount);
    }

    /// @dev Property 6: Health Factor Gate Enforcement (remove-collateral path)
    /// Validates: Requirements 6.3
    function testFuzz_property6_removeCollateralHealthFactorGate(
        uint128 debtRaw,
        uint128 collateralBeforeRaw,
        uint128 removeRaw
    ) public {
        uint256 debt = bound(uint256(debtRaw), 1, 1e24);
        uint256 requiredSafe = Math.ceilDiv(debt * IlmTypes.BPS, uint256(LT_BPS));
        uint256 collateralBefore = bound(uint256(collateralBeforeRaw), requiredSafe + 1, requiredSafe + 1e24);
        uint256 maxUnsafeAfter = requiredSafe - 1;
        uint256 collateralAfter = bound(uint256(removeRaw), 0, maxUnsafeAfter);
        uint256 removeAmount = collateralBefore - collateralAfter;

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: LT_BPS,
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
        h.seedModuleEncumbrance(positionKey, COLLATERAL_POOL_ID, MODULE_ID, collateralBefore);

        vm.prank(OWNER);
        vm.expectRevert();
        h.pooledRemoveCollateral(positionId, MARKET_ID, removeAmount);
    }
}

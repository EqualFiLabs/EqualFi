// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {IlmTypes} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";

contract ILMPooledFacetHarnessAci is ILMPooledFacet {
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

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function getPoolActiveCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function getPoolUserActiveCreditEncumbrancePrincipal(uint256 poolId, bytes32 positionKey)
        external
        view
        returns (uint256)
    {
        return LibAppStorage.s().pools[poolId].userActiveCreditStateEncumbrance[positionKey].principal;
    }
}

contract ILMActiveCreditCouplingPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;
    address internal constant OWNER = address(0xA11CE);

    ILMPooledFacetHarnessAci internal h;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessAci();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        positionId = nft.mint(OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);

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
            scaledVariableDebtTotal: 0,
            availableLiquidity: 0,
            badDebt: 0
        });
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 10_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, positionKey, 10_000);
    }

    /// @dev Property 33: Active Credit Increase Gate
    /// Validates: Requirements 17.1, 17.3
    function test_property33_activeCreditIncreaseGate() public {
        h.setModuleAciPausedRaw(false);
        vm.prank(OWNER);
        h.pooledSupply(positionId, MARKET_ID, 120);
        assertEq(h.getPoolActiveCreditPrincipalTotal(LOAN_POOL_ID), 120);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(LOAN_POOL_ID, positionKey), 120);

        h.setModuleAciPausedRaw(true);
        vm.prank(OWNER);
        h.pooledSupply(positionId, MARKET_ID, 40);
        assertEq(h.getPoolActiveCreditPrincipalTotal(LOAN_POOL_ID), 120);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(LOAN_POOL_ID, positionKey), 120);

        h.setModuleAciPausedRaw(false);
        vm.prank(OWNER);
        h.pooledAddCollateral(positionId, MARKET_ID, 75);
        assertEq(h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID), 75);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(COLLATERAL_POOL_ID, positionKey), 75);

        h.setModuleAciPausedRaw(true);
        vm.prank(OWNER);
        h.pooledAddCollateral(positionId, MARKET_ID, 25);
        assertEq(h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID), 75);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(COLLATERAL_POOL_ID, positionKey), 75);
    }

    /// @dev Property 34: Active Credit Decrease Always On
    /// Validates: Requirements 17.2
    function test_property34_activeCreditDecreaseAlwaysOn() public {
        h.setModuleAciPausedRaw(false);
        vm.startPrank(OWNER);
        h.pooledSupply(positionId, MARKET_ID, 100);
        h.pooledAddCollateral(positionId, MARKET_ID, 60);
        vm.stopPrank();

        assertEq(h.getPoolActiveCreditPrincipalTotal(LOAN_POOL_ID), 100);
        assertEq(h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID), 60);

        h.setModuleAciPausedRaw(true);
        vm.startPrank(OWNER);
        h.pooledWithdraw(positionId, MARKET_ID, 40);
        h.pooledRemoveCollateral(positionId, MARKET_ID, 20);
        vm.stopPrank();

        assertEq(h.getPoolActiveCreditPrincipalTotal(LOAN_POOL_ID), 60);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(LOAN_POOL_ID, positionKey), 60);
        assertEq(h.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID), 40);
        assertEq(h.getPoolUserActiveCreditEncumbrancePrincipal(COLLATERAL_POOL_ID, positionKey), 40);
    }
}

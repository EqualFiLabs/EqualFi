// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {IlmTypes, IlmUnauthorized} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../../src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol";
import {IIlmOracleAdapter} from "../../src/ilm-pooled/interfaces/IIlmOracleAdapter.sol";

contract MockIlmOracleAdapterAuth is IIlmOracleAdapter {
    uint256 internal _priceRay = 1e27;

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract ILMPooledFacetHarnessAuth is ILMPooledFacet {
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

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function getPosition(uint256 marketId, bytes32 positionKey) external view returns (IlmTypes.IlmPosition memory) {
        return LibIlmStorage.s().positions[marketId][positionKey];
    }
}

contract ILMPooledLiquidationHarnessAuth is ILMPooledLiquidationFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
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

    function setOracleAdapterRaw(address oracle) external {
        LibIlmStorage.s().oracleAdapter = oracle;
    }

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }
}

contract ILMAuthorizationPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant RANDOM = address(0xBAD);
    address internal constant BORROWER = address(0xC0DE);

    ILMPooledFacetHarnessAuth internal h;
    ILMPooledLiquidationHarnessAuth internal hl;
    MockIlmOracleAdapterAuth internal oracle;
    PositionNFT internal nft;

    uint256 internal ownerPositionId;
    bytes32 internal ownerPositionKey;
    uint256 internal borrowerPositionId;
    bytes32 internal borrowerKey;
    uint256 internal liquidatorPositionId;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessAuth();
        hl = new ILMPooledLiquidationHarnessAuth();
        oracle = new MockIlmOracleAdapterAuth();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        hl.setPositionNftRaw(address(nft), true);
        hl.setOracleAdapterRaw(address(oracle));

        ownerPositionId = nft.mint(OWNER, LOAN_POOL_ID);
        ownerPositionKey = nft.getPositionKey(ownerPositionId);

        borrowerPositionId = nft.mint(BORROWER, LOAN_POOL_ID);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        liquidatorPositionId = nft.mint(OWNER, LOAN_POOL_ID);
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);
    }

    /// @dev Requirement 18.1: pooled mutators require owner or authorized operator.
    function test_property35_pooledMutatorsRequireAuthorization() public {
        IlmTypes.IlmMarket memory market = _market();
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledSupply(ownerPositionId, MARKET_ID, 1);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledWithdraw(ownerPositionId, MARKET_ID, 1);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledBorrow(ownerPositionId, MARKET_ID, 1);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledRepay(ownerPositionId, MARKET_ID, 1);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledAddCollateral(ownerPositionId, MARKET_ID, 1);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        h.pooledRemoveCollateral(ownerPositionId, MARKET_ID, 1);
    }

    /// @dev Requirement 18.1: authorized operator can run all pooled mutators.
    function test_authorizedOperatorCanRunPooledMutators() public {
        IlmTypes.IlmMarket memory market = _market();
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, ownerPositionKey, 0, 0, false);
        h.setPoolPrincipal(LOAN_POOL_ID, ownerPositionKey, 1_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 1_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, ownerPositionKey, 1_000);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 1_000);
        h.setAuthorizationRaw(ownerPositionKey, OPERATOR, true);

        vm.startPrank(OPERATOR);
        h.pooledSupply(ownerPositionId, MARKET_ID, 100);
        h.pooledBorrow(ownerPositionId, MARKET_ID, 20);
        h.pooledRepay(ownerPositionId, MARKET_ID, 20);
        h.pooledAddCollateral(ownerPositionId, MARKET_ID, 50);
        h.pooledWithdraw(ownerPositionId, MARKET_ID, 10);
        h.pooledRemoveCollateral(ownerPositionId, MARKET_ID, 10);
        vm.stopPrank();

        IlmTypes.IlmPosition memory pos = h.getPosition(MARKET_ID, ownerPositionKey);
        assertGt(pos.scaledSupply, 0);
    }

    /// @dev Property 35: liquidation enforces auth only on liquidator position.
    function test_property35_liquidatorOnlyAuthorizationInLiquidation() public {
        IlmTypes.IlmMarket memory market = _market();
        market.scaledVariableDebtTotal = 100;

        hl.setMarketRaw(MARKET_ID, market, MODULE_ID);
        hl.setPositionRaw(MARKET_ID, borrowerKey, 0, 100, false);
        hl.setPositionRaw(MARKET_ID, liquidatorKey, 0, 0, false);
        hl.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 200);
        hl.setPoolTotalDeposits(LOAN_POOL_ID, 200);
        hl.setPoolTrackedBalance(LOAN_POOL_ID, 1_000);
        hl.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 100);
        hl.setPoolTotalDeposits(COLLATERAL_POOL_ID, 100);
        hl.setPoolTrackedBalance(COLLATERAL_POOL_ID, 1_000);
        hl.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 100);

        vm.prank(RANDOM);
        vm.expectRevert(IlmUnauthorized.selector);
        hl.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 10);

        hl.setAuthorizationRaw(liquidatorKey, RANDOM, true);
        vm.prank(RANDOM);
        (uint256 debtLiquidated, uint256 seized) =
            hl.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 10);
        assertGt(debtLiquidated, 0);
        assertGt(seized, 0);
    }

    function _market() internal view returns (IlmTypes.IlmMarket memory market) {
        market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 0,
            liquidationProtocolFeeBps: 0,
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
}

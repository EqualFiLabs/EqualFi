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
    IlmReservePaused,
    IlmReserveFrozen
} from "../../src/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {ILMPooledFacet} from "../../src/modules/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../../src/modules/ILMPooledLiquidationFacet.sol";
import {IIlmOracleAdapter} from "../../src/interfaces/IIlmOracleAdapter.sol";

contract MockIlmOracleAdapterGov is IIlmOracleAdapter {
    uint256 internal _priceRay = 1e27;

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract ILMPooledFacetHarnessGov is ILMPooledFacet {
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

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }
}

contract ILMPooledLiquidationHarnessGov is ILMPooledLiquidationFacet {
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

    function setOracleAdapterRaw(address oracle) external {
        LibIlmStorage.s().oracleAdapter = oracle;
    }

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }
}

contract ILMGovernanceFlagsPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;

    address internal constant OWNER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B0);
    address internal constant LIQUIDATOR = address(0xCAFE);

    ILMPooledFacetHarnessGov internal h;
    ILMPooledLiquidationHarnessGov internal hl;
    MockIlmOracleAdapterGov internal oracle;
    PositionNFT internal nft;

    uint256 internal ownerPositionId;
    bytes32 internal ownerPositionKey;
    uint256 internal repayPositionId;
    bytes32 internal repayPositionKey;
    uint256 internal borrowerPositionId;
    bytes32 internal borrowerKey;
    uint256 internal liquidatorPositionId;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMPooledFacetHarnessGov();
        hl = new ILMPooledLiquidationHarnessGov();
        oracle = new MockIlmOracleAdapterGov();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        hl.setPositionNftRaw(address(nft), true);
        hl.setOracleAdapterRaw(address(oracle));

        ownerPositionId = nft.mint(OWNER, LOAN_POOL_ID);
        ownerPositionKey = nft.getPositionKey(ownerPositionId);
        repayPositionId = nft.mint(OWNER, LOAN_POOL_ID);
        repayPositionKey = nft.getPositionKey(repayPositionId);

        borrowerPositionId = nft.mint(BORROWER, LOAN_POOL_ID);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        liquidatorPositionId = nft.mint(LIQUIDATOR, LOAN_POOL_ID);
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);
    }

    /// @dev Property 24: Paused market rejects all mutations.
    function test_property24_pausedMarketRejectsAllMutations() public {
        IlmTypes.IlmMarket memory market = _market(true, false);
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        hl.setMarketRaw(MARKET_ID, market, MODULE_ID);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledSupply(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledWithdraw(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledBorrow(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledRepay(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledAddCollateral(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        h.pooledRemoveCollateral(ownerPositionId, MARKET_ID, 1);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IlmReservePaused.selector, MARKET_ID));
        hl.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 1);
    }

    /// @dev Property 25: Frozen market rejects supply/borrow but allows withdraw/repay/liquidation.
    function test_property25_frozenMarketSelectiveRejection() public {
        IlmTypes.IlmMarket memory market = _market(false, true);
        market.scaledSupplyTotal = 100;
        market.scaledVariableDebtTotal = 50;
        market.availableLiquidity = 200;

        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setPositionRaw(MARKET_ID, ownerPositionKey, 100, 0, true);
        h.setPositionRaw(MARKET_ID, repayPositionKey, 0, 50, false);
        h.setPoolPrincipal(LOAN_POOL_ID, ownerPositionKey, 1_000);
        h.setPoolPrincipal(LOAN_POOL_ID, repayPositionKey, 1_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 1_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, ownerPositionKey, 1_000);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 1_000);
        h.seedModuleEncumbrance(ownerPositionKey, LOAN_POOL_ID, MODULE_ID, 100);
        h.seedModuleEncumbrance(ownerPositionKey, COLLATERAL_POOL_ID, MODULE_ID, 100);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReserveFrozen.selector, MARKET_ID));
        h.pooledSupply(ownerPositionId, MARKET_ID, 10);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmReserveFrozen.selector, MARKET_ID));
        h.pooledBorrow(ownerPositionId, MARKET_ID, 10);

        vm.prank(OWNER);
        uint256 withdrawn = h.pooledWithdraw(ownerPositionId, MARKET_ID, 10);
        assertEq(withdrawn, 10);

        vm.prank(OWNER);
        uint256 repaid = h.pooledRepay(repayPositionId, MARKET_ID, 10);
        assertEq(repaid, 10);

        IlmTypes.IlmMarket memory liqMarket = _market(false, true);
        liqMarket.scaledVariableDebtTotal = 100;

        hl.setMarketRaw(MARKET_ID, liqMarket, MODULE_ID);
        hl.setPositionRaw(MARKET_ID, borrowerKey, 0, 100, false);
        hl.setPositionRaw(MARKET_ID, liquidatorKey, 0, 0, false);
        hl.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 500);
        hl.setPoolTotalDeposits(LOAN_POOL_ID, 500);
        hl.setPoolTrackedBalance(LOAN_POOL_ID, 2_000);
        hl.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 100);
        hl.setPoolTotalDeposits(COLLATERAL_POOL_ID, 100);
        hl.setPoolTrackedBalance(COLLATERAL_POOL_ID, 2_000);
        hl.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 100);

        vm.prank(LIQUIDATOR);
        (uint256 debtLiquidated, uint256 seized) =
            hl.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 40);
        assertGt(debtLiquidated, 0);
        assertGt(seized, 0);
    }

    function _market(bool paused, bool frozen) internal view returns (IlmTypes.IlmMarket memory market) {
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
            paused: paused,
            frozen: frozen,
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

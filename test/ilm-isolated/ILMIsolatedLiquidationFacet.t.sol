// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {ILMIsolatedLiquidationFacet} from "../../src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterLiquidation is IIlmIsolatedIrmAdapter {
    uint256 internal _ratePerSecond;

    function setRate(uint256 ratePerSecond) external {
        _ratePerSecond = ratePerSecond;
    }

    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external view returns (uint256 ratePerSecond) {
        return _ratePerSecond;
    }
}

contract MockIlmIsolatedOracleAdapterLiquidation is IIlmIsolatedOracleAdapter {
    uint256 internal _price;
    uint256 internal _updatedAt;

    function setPrice(uint256 price, uint256 updatedAt) external {
        _price = price;
        _updatedAt = updatedAt;
    }

    function getIsolatedPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}

contract ILMIsolatedLiquidationFacetHarness is ILMIsolatedLiquidationFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setMaxStalenessRaw(uint256 maxStaleness) external {
        LibIlmIsolatedStorage.s().maxStaleness = maxStaleness;
    }

    function setMarket(
        bytes32 marketId,
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata params,
        IlmIsolatedTypes.IlmIsolatedMarket calldata market,
        uint256 moduleId
    ) external {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage ds_ = LibIlmIsolatedStorage.s();
        ds_.marketParams[marketId] = params;
        ds_.market[marketId] = market;
        ds_.marketModuleId[marketId] = moduleId;
    }

    function setPositionBorrowAndCollateral(
        bytes32 marketId,
        bytes32 positionKey,
        uint128 borrowShares,
        uint128 collateralAssets
    ) external {
        LibIlmIsolatedStorage.s().position[marketId][positionKey].borrowShares = borrowShares;
        LibIlmIsolatedStorage.s().position[marketId][positionKey].collateralAssets = collateralAssets;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
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

    function setGlobalFeeSplits(uint16 treasuryBps, uint16 activeCreditBps) external {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.treasuryShareConfigured = true;
        app.treasuryShareBps = treasuryBps;
        app.activeCreditShareConfigured = true;
        app.activeCreditShareBps = activeCreditBps;
    }

    function setPoolFeeIndex(uint256 poolId, uint256 feeIndex) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].feeIndex = feeIndex;
    }

    function setPoolUserFeeIndex(uint256 poolId, bytes32 positionKey, uint256 feeIndex) external {
        LibAppStorage.s().pools[poolId].userFeeIndex[positionKey] = feeIndex;
    }

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function getPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory)
    {
        return LibIlmIsolatedStorage.s().position[marketId][positionKey];
    }

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
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

    function getPoolUserFeeIndex(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userFeeIndex[positionKey];
    }

    function getPoolUserAccruedYield(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userAccruedYield[positionKey];
    }

    function pendingFeeYield(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibFeeIndex.pendingYield(poolId, positionKey);
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }

    function setMarketLiquidationFeeBps(bytes32 marketId, uint16 bps) external {
        LibIlmIsolatedStorage.s().marketLiquidationFeeBps[marketId] = bps;
    }

    function setMarketProtocolFeeAssets(bytes32 marketId, uint256 feeAssets) external {
        LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId] = feeAssets;
    }

    function getMarketProtocolFeeAssets(bytes32 marketId) external view returns (uint256) {
        return LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId];
    }
}

contract ILMIsolatedLiquidationFacetTest is Test {
    bytes32 internal constant MARKET_A = keccak256("ilm.isolated.market.a");
    bytes32 internal constant MARKET_B = keccak256("ilm.isolated.market.b");
    uint256 internal constant LOAN_POOL_ID = 501;
    uint256 internal constant COLLATERAL_POOL_ID = 502;
    uint256 internal constant MODULE_ID = 88;
    uint256 internal constant LLTV = 5e17;

    address internal constant BORROWER_OWNER = address(0xB0B0);
    address internal constant LIQUIDATOR_OWNER = address(0x1A1A);

    ILMIsolatedLiquidationFacetHarness internal h;
    MockIlmIsolatedIrmAdapterLiquidation internal irm;
    MockIlmIsolatedOracleAdapterLiquidation internal oracle;
    PositionNFT internal nft;

    uint256 internal borrowerPositionId;
    uint256 internal liquidatorPositionId;
    bytes32 internal borrowerKey;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMIsolatedLiquidationFacetHarness();
        irm = new MockIlmIsolatedIrmAdapterLiquidation();
        oracle = new MockIlmIsolatedOracleAdapterLiquidation();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        h.setMaxStalenessRaw(1 days);
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        borrowerPositionId = nft.mint(BORROWER_OWNER, LOAN_POOL_ID);
        liquidatorPositionId = nft.mint(LIQUIDATOR_OWNER, LOAN_POOL_ID);
        borrowerKey = nft.getPositionKey(borrowerPositionId);
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);
    }

    /// @dev Property 14: Healthy Position Liquidation Rejection
    /// Validates: Requirement 10.5
    function test_property14_healthyPositionLiquidationRejection() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 3_000_000,
                totalSupplyShares: 3_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        // healthy under virtual-shares math.
        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 500, 1500);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 1500);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 10_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 10_000);

        vm.prank(LIQUIDATOR_OWNER);
        vm.expectRevert(IlmIsolatedHealthyPosition.selector);
        h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);
    }

    /// @dev Property 15: Liquidation Dual-Input Consistency
    /// Validates: Requirements 10.3, 10.4
    function test_property15_liquidationDualInputConsistency() public {
        (
            ILMIsolatedLiquidationFacetHarness h1,
            PositionNFT nft1,
            uint256 borrowerId1,
            uint256 liquidatorId1,
            bytes32 borrowerKey1,
            bytes32 liquidatorKey1
        ) = _createScenarioHarness();

        uint256 borrowSharesBefore = h1.getPosition(MARKET_A, borrowerKey1).borrowShares;
        vm.prank(LIQUIDATOR_OWNER);
        (, uint256 repaidAssetsFromSeized) = h1.isolatedLiquidate(MARKET_A, borrowerId1, 100, 0, liquidatorId1);
        uint256 borrowSharesAfter = h1.getPosition(MARKET_A, borrowerKey1).borrowShares;
        uint256 repaidSharesFromSeized = borrowSharesBefore - borrowSharesAfter;

        (
            ILMIsolatedLiquidationFacetHarness h2,
            PositionNFT nft2,
            uint256 borrowerId2,
            uint256 liquidatorId2,
            bytes32 borrowerKey2,
            bytes32 liquidatorKey2
        ) = _createScenarioHarness();

        vm.prank(LIQUIDATOR_OWNER);
        (, uint256 repaidAssetsFromShares) =
            h2.isolatedLiquidate(MARKET_A, borrowerId2, 0, repaidSharesFromSeized, liquidatorId2);

        assertEq(repaidAssetsFromShares, repaidAssetsFromSeized);

        // Ensure liquidator key really participates in settlement.
        assertLt(h2.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey2), 5000);
        nft1;
        nft2;
        liquidatorKey1;
        borrowerKey2;
    }

    /// @dev Property 16: Liquidation State Consistency
    /// Validates: Requirements 10.1, 10.6, 17.7
    function test_property16_liquidationStateConsistency() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 800_000, 300);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 2_000_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 2_000_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 300);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 50);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 350);

        uint256 borrowerBorrowSharesBefore = h.getPosition(MARKET_A, borrowerKey).borrowShares;
        uint256 borrowerCollateralBefore = h.getPosition(MARKET_A, borrowerKey).collateralAssets;
        IlmIsolatedTypes.IlmIsolatedMarket memory marketBefore = h.getMarket(MARKET_A);
        uint256 liquidatorLoanPrincipalBefore = h.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey);
        uint256 borrowerCollateralPrincipalBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey);
        uint256 liquidatorCollateralPrincipalBefore = h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);
        uint256 collateralPoolDepositsBefore = h.getPoolTotalDeposits(COLLATERAL_POOL_ID);
        uint256 borrowerEncBefore = h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID);

        vm.prank(LIQUIDATOR_OWNER);
        (uint256 seizedOut, uint256 repaidAssetsOut) =
            h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedPosition memory borrowerAfter = h.getPosition(MARKET_A, borrowerKey);
        IlmIsolatedTypes.IlmIsolatedMarket memory marketAfter = h.getMarket(MARKET_A);

        uint256 repaidSharesUsed = borrowerBorrowSharesBefore - borrowerAfter.borrowShares;
        uint256 grossSeized = borrowerCollateralBefore - borrowerAfter.collateralAssets;
        uint256 protocolFeeCollateral = grossSeized - seizedOut;

        assertEq(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets - repaidAssetsOut);
        assertEq(marketAfter.totalBorrowShares, marketBefore.totalBorrowShares - repaidSharesUsed);
        assertEq(borrowerAfter.collateralAssets, borrowerCollateralBefore - grossSeized);
        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey), liquidatorLoanPrincipalBefore - repaidAssetsOut);
        assertEq(h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey), borrowerCollateralPrincipalBefore - grossSeized);
        assertEq(
            h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey), liquidatorCollateralPrincipalBefore + seizedOut
        );
        assertEq(h.getPoolTotalDeposits(COLLATERAL_POOL_ID), collateralPoolDepositsBefore - protocolFeeCollateral);
        assertEq(h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID), borrowerEncBefore - grossSeized);
    }

    /// @dev Property 17: Bad Debt Realization
    /// Validates: Requirements 11.1, 11.2
    function test_property17_badDebtRealization() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 1_000_000, 100);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 100);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 5000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 5000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 100);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 100);

        IlmIsolatedTypes.IlmIsolatedMarket memory beforeMarket = h.getMarket(MARKET_A);

        vm.prank(LIQUIDATOR_OWNER);
        (, uint256 repaidAssetsOut) = h.isolatedLiquidate(MARKET_A, borrowerPositionId, 100, 0, liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedMarket memory afterMarket = h.getMarket(MARKET_A);
        IlmIsolatedTypes.IlmIsolatedPosition memory afterBorrower = h.getPosition(MARKET_A, borrowerKey);

        uint256 borrowDrop = beforeMarket.totalBorrowAssets - afterMarket.totalBorrowAssets;
        uint256 supplyDrop = beforeMarket.totalSupplyAssets - afterMarket.totalSupplyAssets;

        assertEq(afterBorrower.collateralAssets, 0);
        assertEq(afterBorrower.borrowShares, 0);
        assertEq(afterMarket.totalBorrowShares, 0);
        assertGt(borrowDrop, repaidAssetsOut);
        assertEq(supplyDrop, borrowDrop - repaidAssetsOut);
    }

    /// @dev Property 18: Bad Debt Market Isolation
    /// Validates: Requirement 11.3
    function test_property18_badDebtMarketIsolation() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        _setMarketB(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 5555,
                totalSupplyShares: 4444,
                totalBorrowAssets: 3333,
                totalBorrowShares: 2222,
                lastUpdate: uint128(block.timestamp),
                fee: uint128(1e17)
            })
        );

        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 1_000_000, 100);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 100);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 5000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 5000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 100);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 100);

        IlmIsolatedTypes.IlmIsolatedMarket memory beforeB = h.getMarket(MARKET_B);

        vm.prank(LIQUIDATOR_OWNER);
        h.isolatedLiquidate(MARKET_A, borrowerPositionId, 100, 0, liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedMarket memory afterB = h.getMarket(MARKET_B);
        assertEq(afterB.totalSupplyAssets, beforeB.totalSupplyAssets);
        assertEq(afterB.totalSupplyShares, beforeB.totalSupplyShares);
        assertEq(afterB.totalBorrowAssets, beforeB.totalBorrowAssets);
        assertEq(afterB.totalBorrowShares, beforeB.totalBorrowShares);
        assertEq(afterB.lastUpdate, beforeB.lastUpdate);
        assertEq(afterB.fee, beforeB.fee);
    }

    /// @dev Property 24: Authorization Enforcement (liquidation path)
    /// Validates: Requirements 16.2, 16.3, 16.4
    function test_property24_authorizationEnforcement_liquidationFacet() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        // Unhealthy borrower for liquidation path.
        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 800_000, 300);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 50_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 50_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 300);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 0);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 300);

        address unauthorized = address(0xDEAD);
        vm.prank(unauthorized);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);

        // Borrower side remains permissionless once liquidator position auth is valid.
        h.setAuthorizationRaw(liquidatorKey, unauthorized, true);
        vm.prank(unauthorized);
        h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);
    }

    function test_liquidation_withProtocolFeeBps_returnsNetAndRoutesFee() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setMarketLiquidationFeeBps(MARKET_A, 500);
        h.setGlobalFeeSplits(0, 0);
        h.setPoolTrackedBalance(COLLATERAL_POOL_ID, 10_000_000);

        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 800_000, 300);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 50_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 50_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 300);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 0);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 300);

        vm.prank(LIQUIDATOR_OWNER);
        (uint256 seizedOut,) = h.isolatedLiquidate(MARKET_A, borrowerPositionId, 100, 0, liquidatorPositionId);

        assertEq(seizedOut, 95);
        assertEq(h.getPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey), 200);
        assertEq(h.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey), 95);
        assertEq(h.getPoolTotalDeposits(COLLATERAL_POOL_ID), 295);
        assertEq(h.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID), 200);
        assertGt(h.getPoolFeeIndex(COLLATERAL_POOL_ID), 0);
    }

    function test_liquidation_realizesDeferredInterestClaimProRata() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setGlobalFeeSplits(0, 0);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 10_000_000);
        h.setMarketProtocolFeeAssets(MARKET_A, 2_000);

        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 800_000, 300);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 50_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 50_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 300);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 0);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 300);

        uint256 borrowBefore = h.getMarket(MARKET_A).totalBorrowAssets;
        vm.prank(LIQUIDATOR_OWNER);
        (, uint256 repaidAssetsOut) = h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);

        uint256 expectedClaimAfter = 2_000 - ((2_000 * repaidAssetsOut) / borrowBefore);
        assertEq(h.getMarketProtocolFeeAssets(MARKET_A), expectedClaimAfter);
    }

    function test_liquidation_badDebtWriteDown_clearsDeferredInterestClaim() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setGlobalFeeSplits(0, 0);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 10_000_000);
        h.setMarketProtocolFeeAssets(MARKET_A, 5_000);

        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 1_000_000, 100);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 100);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 5_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 5_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 100);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 100);

        uint256 claimBefore = h.getMarketProtocolFeeAssets(MARKET_A);
        uint256 borrowBefore = h.getMarket(MARKET_A).totalBorrowAssets;

        vm.prank(LIQUIDATOR_OWNER);
        (, uint256 repaidAssetsOut) = h.isolatedLiquidate(MARKET_A, borrowerPositionId, 100, 0, liquidatorPositionId);

        uint256 borrowAfter = h.getMarket(MARKET_A).totalBorrowAssets;
        uint256 badDebtAssets = borrowBefore - borrowAfter - repaidAssetsOut;
        uint256 borrowBeforeWriteDown = borrowBefore - repaidAssetsOut;

        uint256 claimAfterWriteDown = claimBefore - ((claimBefore * badDebtAssets) / borrowBeforeWriteDown);
        uint256 realized = (claimAfterWriteDown * repaidAssetsOut) / borrowBefore;
        uint256 expectedClaimAfter = claimAfterWriteDown - realized;
        if (borrowAfter == 0) {
            expectedClaimAfter = 0;
        }

        assertEq(h.getMarketProtocolFeeAssets(MARKET_A), expectedClaimAfter);
    }

    function test_liquidationCollateralCredit_checkpointsFeeIndex() public {
        _setMarketA(
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setPositionBorrowAndCollateral(MARKET_A, borrowerKey, 800_000, 300);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 50_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 50_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 300);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 0);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 300);

        uint256 feeIndex = 4e18;
        h.setPoolFeeIndex(COLLATERAL_POOL_ID, feeIndex);
        h.setPoolUserFeeIndex(COLLATERAL_POOL_ID, liquidatorKey, 0);

        vm.prank(LIQUIDATOR_OWNER);
        h.isolatedLiquidate(MARKET_A, borrowerPositionId, 0, 100, liquidatorPositionId);

        assertEq(h.getPoolUserFeeIndex(COLLATERAL_POOL_ID, liquidatorKey), feeIndex);
        assertEq(h.getPoolUserAccruedYield(COLLATERAL_POOL_ID, liquidatorKey), 0);
        assertEq(h.pendingFeeYield(COLLATERAL_POOL_ID, liquidatorKey), 0);
    }

    function _setMarketA(IlmIsolatedTypes.IlmIsolatedMarket memory market) internal {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        h.setMarket(MARKET_A, params, market, MODULE_ID);
    }

    function _setMarketB(IlmIsolatedTypes.IlmIsolatedMarket memory market) internal {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID + 10,
            collateralPoolId: COLLATERAL_POOL_ID + 10,
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        h.setMarket(MARKET_B, params, market, MODULE_ID + 1);
    }

    function _createScenarioHarness()
        internal
        returns (
            ILMIsolatedLiquidationFacetHarness h_,
            PositionNFT nft_,
            uint256 borrowerId_,
            uint256 liquidatorId_,
            bytes32 borrowerKey_,
            bytes32 liquidatorKey_
        )
    {
        h_ = new ILMIsolatedLiquidationFacetHarness();
        MockIlmIsolatedIrmAdapterLiquidation irm_ = new MockIlmIsolatedIrmAdapterLiquidation();
        MockIlmIsolatedOracleAdapterLiquidation oracle_ = new MockIlmIsolatedOracleAdapterLiquidation();
        nft_ = new PositionNFT();
        nft_.setMinter(address(this));

        h_.setPositionNftRaw(address(nft_), true);
        h_.setMaxStalenessRaw(1 days);
        oracle_.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        borrowerId_ = nft_.mint(BORROWER_OWNER, LOAN_POOL_ID);
        liquidatorId_ = nft_.mint(LIQUIDATOR_OWNER, LOAN_POOL_ID);
        borrowerKey_ = nft_.getPositionKey(borrowerId_);
        liquidatorKey_ = nft_.getPositionKey(liquidatorId_);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            oracle: address(oracle_),
            irm: address(irm_),
            lltv: LLTV
        });
        h_.setMarket(
            MARKET_A,
            params,
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 3_000_000,
                totalSupplyShares: 3_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            }),
            MODULE_ID
        );
        // unhealthy under virtual-shares math.
        h_.setPositionBorrowAndCollateral(MARKET_A, borrowerKey_, 800_000, 300);
        h_.seedModuleEncumbrance(borrowerKey_, COLLATERAL_POOL_ID, MODULE_ID, 300);
        h_.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey_, 5000);
        h_.setPoolTotalDeposits(LOAN_POOL_ID, 5000);
        h_.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey_, 300);
        h_.setPoolTotalDeposits(COLLATERAL_POOL_ID, 300);
    }
}

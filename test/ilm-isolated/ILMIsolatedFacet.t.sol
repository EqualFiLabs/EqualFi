// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";
import {LibIlmLiquidationMath} from "../../src/ilm-isolated/libraries/LibIlmLiquidationMath.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterFacet is IIlmIsolatedIrmAdapter {
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

contract MockIlmIsolatedOracleAdapterFacet is IIlmIsolatedOracleAdapter {
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

contract ILMIsolatedFacetHarness is ILMIsolatedFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
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

    function setPositionSupplyShares(bytes32 marketId, bytes32 positionKey, uint256 shares) external {
        LibIlmIsolatedStorage.s().position[marketId][positionKey].supplyShares = shares;
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

    function setMaxStalenessRaw(uint256 maxStaleness) external {
        LibIlmIsolatedStorage.s().maxStaleness = maxStaleness;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function setPoolTotals(uint256 poolId, uint256 totalDeposits) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].totalDeposits = totalDeposits;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function setPoolActionFee(uint256 poolId, bytes32 action, uint128 amount, bool enabled) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].actionFees[action] = Types.ActionFeeConfig({amount: amount, enabled: enabled});
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

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
    }

    function getPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory)
    {
        return LibIlmIsolatedStorage.s().position[marketId][positionKey];
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
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

    function setMarketProtocolFeeAssets(bytes32 marketId, uint256 feeAssets) external {
        LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId] = feeAssets;
    }

    function getMarketProtocolFeeAssets(bytes32 marketId) external view returns (uint256) {
        return LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId];
    }
}

contract ILMIsolatedFacetTest is Test {
    bytes32 internal constant MARKET_ID = keccak256("ilm.isolated.market");
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant MODULE_ID = 77;
    address internal constant POSITION_OWNER = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant ATTACKER = address(0xCAFE);

    ILMIsolatedFacetHarness internal h;
    MockIlmIsolatedIrmAdapterFacet internal irm;
    MockIlmIsolatedOracleAdapterFacet internal oracle;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMIsolatedFacetHarness();
        irm = new MockIlmIsolatedIrmAdapterFacet();
        oracle = new MockIlmIsolatedOracleAdapterFacet();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        h.setMaxStalenessRaw(1 days);
        positionId = nft.mint(POSITION_OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);
    }

    /// @dev Property 6: Supply State Consistency
    /// Validates: Requirements 2.1, 17.1
    function testFuzz_property6_supplyStateConsistency(
        uint128 totalSupplyAssetsRaw,
        uint128 totalSupplySharesRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 positionSupplySharesRaw,
        uint128 supplyAssetsRaw,
        uint128 principalBufferRaw
    ) public {
        uint256 totalSupplyAssets = bound(uint256(totalSupplyAssetsRaw), 0, 1e24);
        uint256 totalSupplyShares = bound(uint256(totalSupplySharesRaw), 0, 1e24);
        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 0, totalSupplyAssets);
        uint256 positionSupplySharesStart = bound(uint256(positionSupplySharesRaw), 0, 1e24);
        uint256 supplyAssets = bound(uint256(supplyAssetsRaw), 1, 1e24);
        uint256 principalBuffer = bound(uint256(principalBufferRaw), 0, 1e24);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: uint128(totalSupplyShares),
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionSupplyShares(MARKET_ID, positionKey, positionSupplySharesStart);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, supplyAssets + principalBuffer);

        uint256 expectedShares = LibIlmSharesMath.toSharesDown(supplyAssets, totalSupplyAssets, totalSupplyShares);
        vm.assume(totalSupplyAssets + supplyAssets <= type(uint128).max);
        vm.assume(totalSupplyShares + expectedShares <= type(uint128).max);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedSupply(MARKET_ID, supplyAssets, 0, positionId);

        assertEq(assetsOut, supplyAssets);
        assertEq(sharesOut, expectedShares);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.supplyShares, positionSupplySharesStart + expectedShares);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalSupplyAssets, totalSupplyAssets + supplyAssets);
        assertEq(gotMarket.totalSupplyShares, totalSupplyShares + expectedShares);
        assertEq(gotMarket.totalBorrowAssets, totalBorrowAssets);

        uint256 encumbered = h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID);
        assertEq(encumbered, supplyAssets);
    }

    /// @dev Property 7: Withdraw State Consistency
    /// Validates: Requirements 3.1, 17.2
    function testFuzz_property7_withdrawStateConsistency(
        bool byAssets,
        uint128 totalSupplyAssetsRaw,
        uint128 totalSupplySharesRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 positionSupplySharesRaw,
        uint128 inputRaw,
        uint128 encumberanceExtraRaw
    ) public {
        uint256 totalSupplyAssets = bound(uint256(totalSupplyAssetsRaw), 1, 1e24);
        uint256 totalSupplyShares = bound(uint256(totalSupplySharesRaw), 1, 1e24);
        uint256 positionSupplySharesStart = bound(uint256(positionSupplySharesRaw), 1, totalSupplyShares);

        uint256 sharesArg;
        uint256 assetsArg;
        uint256 assetsOutExpected;
        uint256 sharesOutExpected;

        if (byAssets) {
            assetsArg = bound(uint256(inputRaw), 1, totalSupplyAssets);
            sharesArg = 0;
            assetsOutExpected = assetsArg;
            sharesOutExpected = LibIlmSharesMath.toSharesUp(assetsArg, totalSupplyAssets, totalSupplyShares);
        } else {
            sharesArg = bound(uint256(inputRaw), 1, positionSupplySharesStart);
            assetsArg = 0;
            sharesOutExpected = sharesArg;
            assetsOutExpected = LibIlmSharesMath.toAssetsDown(sharesArg, totalSupplyAssets, totalSupplyShares);
        }

        vm.assume(sharesOutExpected <= positionSupplySharesStart);
        vm.assume(sharesOutExpected <= totalSupplyShares);
        vm.assume(assetsOutExpected <= totalSupplyAssets);

        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 0, totalSupplyAssets - assetsOutExpected);
        uint256 encumberedStart = assetsOutExpected + bound(uint256(encumberanceExtraRaw), 0, 1e24);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: uint128(totalSupplyShares),
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionSupplyShares(MARKET_ID, positionKey, positionSupplySharesStart);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, encumberedStart + 1);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, encumberedStart);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedWithdraw(MARKET_ID, assetsArg, sharesArg, positionId);

        assertEq(assetsOut, assetsOutExpected);
        assertEq(sharesOut, sharesOutExpected);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.supplyShares, positionSupplySharesStart - sharesOutExpected);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalSupplyAssets, totalSupplyAssets - assetsOutExpected);
        assertEq(gotMarket.totalSupplyShares, totalSupplyShares - sharesOutExpected);
        assertEq(gotMarket.totalBorrowAssets, totalBorrowAssets);

        uint256 encumbered = h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID);
        assertEq(encumbered, encumberedStart - assetsOutExpected);
    }

    function test_supplyAndWithdraw_revertOnInvalidInputPairs() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1000,
            totalSupplyShares: 1000,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1000);

        vm.startPrank(POSITION_OWNER);
        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedSupply(MARKET_ID, 0, 0, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedSupply(MARKET_ID, 1, 1, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedWithdraw(MARKET_ID, 0, 0, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedWithdraw(MARKET_ID, 1, 1, positionId);
        vm.stopPrank();
    }

    function test_supply_revertsForUnauthorizedButAllowsAuthorizedOperator() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 100,
            totalSupplyShares: 100,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1000);

        vm.prank(ATTACKER);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.isolatedSupply(MARKET_ID, 10, 0, positionId);

        h.setAuthorizationRaw(positionKey, OPERATOR, true);
        vm.prank(OPERATOR);
        h.isolatedSupply(MARKET_ID, 10, 0, positionId);
    }

    /// @dev Property 24: Authorization Enforcement (core facet path)
    /// Validates: Requirements 16.2, 16.3
    function test_property24_authorizationEnforcement_coreFacet() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1000,
            totalSupplyShares: 1000,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1000);
        h.setPoolPrincipal(202, positionKey, 1000);

        vm.prank(ATTACKER);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.isolatedSupplyCollateral(MARKET_ID, 10, positionId);

        h.setAuthorizationRaw(positionKey, OPERATOR, true);
        vm.prank(OPERATOR);
        h.isolatedSupplyCollateral(MARKET_ID, 10, positionId);

        h.setAuthorizationRaw(positionKey, OPERATOR, false);
        vm.prank(OPERATOR);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.isolatedSupply(MARKET_ID, 1, 0, positionId);
    }

    /// @dev Property 8: Collateral Supply State Consistency
    /// Validates: Requirements 4.1, 4.3, 17.3
    function testFuzz_property8_collateralSupplyStateConsistency(
        uint128 collateralStartRaw,
        uint128 assetsRaw,
        uint64 marketLastUpdateRaw
    ) public {
        uint256 collateralStart = bound(uint256(collateralStartRaw), 0, type(uint128).max - 1e24);
        uint256 assets = bound(uint256(assetsRaw), 1, 1e24);
        uint256 lastUpdate = bound(uint256(marketLastUpdateRaw), 1, type(uint64).max);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 10_000_000,
            totalSupplyShares: 10_000_000,
            totalBorrowAssets: 1_000_000,
            totalBorrowShares: 1_000_000,
            lastUpdate: uint128(lastUpdate),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 0, uint128(collateralStart));
        h.setPoolPrincipal(202, positionKey, assets + 1000);

        vm.prank(POSITION_OWNER);
        h.isolatedSupplyCollateral(MARKET_ID, assets, positionId);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.collateralAssets, collateralStart + assets);

        uint256 encumbered = h.getEncumberedForModule(positionKey, 202, MODULE_ID);
        assertEq(encumbered, assets);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.lastUpdate, uint128(lastUpdate));
    }

    /// @dev Property 9: Borrow State Consistency with Health Gate
    /// Validates: Requirements 6.1, 6.4, 17.5
    function testFuzz_property9_borrowStateConsistencyWithHealthGate(
        uint128 totalSupplyAssetsRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 totalBorrowSharesRaw,
        uint128 collateralAssetsRaw,
        uint128 borrowAssetsRaw,
        uint128 principalStartRaw
    ) public {
        uint256 totalSupplyAssets = bound(uint256(totalSupplyAssetsRaw), 1e6, 1e24);
        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 0, totalSupplyAssets - 1);
        uint256 totalBorrowShares = bound(uint256(totalBorrowSharesRaw), 1, 1e24);
        uint256 collateralAssets = bound(uint256(collateralAssetsRaw), 1e6, 1e24);
        uint256 borrowAssets = bound(uint256(borrowAssetsRaw), 1, totalSupplyAssets - totalBorrowAssets);
        uint256 principalStart = bound(uint256(principalStartRaw), 0, 1e24);

        uint256 price = IlmIsolatedTypes.ORACLE_PRICE_SCALE;
        oracle.setPrice(price, block.timestamp);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: uint128(totalBorrowShares),
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 0, uint128(collateralAssets));
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, principalStart);
        h.setPoolTotals(LOAN_POOL_ID, principalStart);

        uint256 expectedShares = LibIlmSharesMath.toSharesUp(borrowAssets, totalBorrowAssets, totalBorrowShares);
        uint256 newBorrowAssets = totalBorrowAssets + borrowAssets;
        uint256 newBorrowShares = totalBorrowShares + expectedShares;
        bool healthy = LibIlmLiquidationMath.isHealthy(
            collateralAssets, expectedShares, newBorrowAssets, newBorrowShares, price, 8e17
        );
        vm.assume(healthy);
        vm.assume(newBorrowAssets <= type(uint128).max);
        vm.assume(newBorrowShares <= type(uint128).max);
        vm.assume(expectedShares <= type(uint128).max);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedBorrow(MARKET_ID, borrowAssets, 0, positionId);
        assertEq(assetsOut, borrowAssets);
        assertEq(sharesOut, expectedShares);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.borrowShares, expectedShares);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalBorrowAssets, newBorrowAssets);
        assertEq(gotMarket.totalBorrowShares, newBorrowShares);

        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), principalStart + borrowAssets);

        bool postHealthy = LibIlmLiquidationMath.isHealthy(
            position.collateralAssets,
            position.borrowShares,
            gotMarket.totalBorrowAssets,
            gotMarket.totalBorrowShares,
            price,
            8e17
        );
        assertTrue(postHealthy);
    }

    function test_borrowCreditPrincipal_checkpointsFeeIndex() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1_000_000,
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: 1000,
            totalBorrowShares: 1000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 0, 100_000);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 0);
        h.setPoolTotals(LOAN_POOL_ID, 1_000_000);

        uint256 feeIndex = 3e18;
        h.setPoolFeeIndex(LOAN_POOL_ID, feeIndex);
        h.setPoolUserFeeIndex(LOAN_POOL_ID, positionKey, 0);

        vm.prank(POSITION_OWNER);
        h.isolatedBorrow(MARKET_ID, 1000, 0, positionId);

        assertEq(h.getPoolUserFeeIndex(LOAN_POOL_ID, positionKey), feeIndex);
        assertEq(h.getPoolUserAccruedYield(LOAN_POOL_ID, positionKey), 0);
        assertEq(h.pendingFeeYield(LOAN_POOL_ID, positionKey), 0);
    }

    function test_borrow_chargesBorrowActionFeeAfterPrincipalCredit() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1_000_000,
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: 1000,
            totalBorrowShares: 1000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 0, 100_000);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 500);
        h.setPoolTotals(LOAN_POOL_ID, 1_000_000);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 10_000_000);
        h.setGlobalFeeSplits(0, 0);
        h.setPoolActionFee(LOAN_POOL_ID, ACTION_BORROW, 25, true);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut,) = h.isolatedBorrow(MARKET_ID, 100, 0, positionId);
        assertEq(assetsOut, 100);

        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), 575);
        assertEq(h.getPoolTotalDeposits(LOAN_POOL_ID), 1_000_075);
        assertGt(h.getPoolFeeIndex(LOAN_POOL_ID), 0);
    }

    /// @dev Property 10: Repay State Consistency
    /// Validates: Requirements 7.1, 17.6
    function testFuzz_property10_repayStateConsistency(
        uint128 totalBorrowAssetsRaw,
        uint128 totalBorrowSharesRaw,
        uint128 positionBorrowSharesRaw,
        uint128 repayAssetsRaw,
        uint128 principalRaw
    ) public {
        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 1, 1e24);
        uint256 totalBorrowShares = bound(uint256(totalBorrowSharesRaw), 1, 1e24);
        uint256 positionBorrowShares = bound(uint256(positionBorrowSharesRaw), 1, totalBorrowShares);
        uint256 repayAssets = bound(uint256(repayAssetsRaw), 1, totalBorrowAssets);
        uint256 principalStart = bound(uint256(principalRaw), repayAssets, repayAssets + 1e24);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalBorrowAssets + 1e6),
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: uint128(totalBorrowShares),
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, uint128(positionBorrowShares), 0);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, principalStart);
        h.setPoolTotals(LOAN_POOL_ID, principalStart);

        uint256 expectedShares = LibIlmSharesMath.toSharesDown(repayAssets, totalBorrowAssets, totalBorrowShares);
        vm.assume(expectedShares > 0);
        vm.assume(expectedShares <= positionBorrowShares);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedRepay(MARKET_ID, repayAssets, 0, positionId);
        assertEq(assetsOut, repayAssets);
        assertEq(sharesOut, expectedShares);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.borrowShares, positionBorrowShares - expectedShares);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalBorrowAssets, totalBorrowAssets - repayAssets);
        assertEq(gotMarket.totalBorrowShares, totalBorrowShares - expectedShares);

        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), principalStart - repayAssets);
    }

    function test_repay_chargesRepayActionFeeOnTop() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 2_000_000,
            totalSupplyShares: 2_000_000,
            totalBorrowAssets: 1_000_000,
            totalBorrowShares: 1_000_000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 1_000_000, 1_000_000);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 500);
        h.setPoolTotals(LOAN_POOL_ID, 1_000_000);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 10_000_000);
        h.setGlobalFeeSplits(0, 0);
        h.setPoolActionFee(LOAN_POOL_ID, ACTION_REPAY, 15, true);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedRepay(MARKET_ID, 100, 0, positionId);
        assertEq(assetsOut, 100);
        assertGt(sharesOut, 0);

        assertEq(h.getPoolPrincipal(LOAN_POOL_ID, positionKey), 385);
        assertEq(h.getPoolTotalDeposits(LOAN_POOL_ID), 999_885);
        assertGt(h.getPoolFeeIndex(LOAN_POOL_ID), 0);
    }

    function test_repay_realizesDeferredProtocolInterestFeeClaim() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 2_000_000,
            totalSupplyShares: 2_000_000,
            totalBorrowAssets: 1_000_000,
            totalBorrowShares: 1_000_000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 1_000_000, 1_000_000);
        h.setMarketProtocolFeeAssets(MARKET_ID, 2_000);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1_000_000);
        h.setPoolTotals(LOAN_POOL_ID, 1_500_000);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 10_000_000);
        h.setGlobalFeeSplits(0, 0);

        vm.prank(POSITION_OWNER);
        h.isolatedRepay(MARKET_ID, 250_000, 0, positionId);

        uint256 expectedClaimAfter = 2_000 - ((2_000 * 250_000) / 1_000_000);
        assertEq(h.getMarketProtocolFeeAssets(MARKET_ID), expectedClaimAfter);
    }

    /// @dev Property 12: Health Gate Enforcement
    /// Validates: Requirements 5.3, 6.4
    function test_property12_healthGateEnforcement() public {
        uint256 price = IlmIsolatedTypes.ORACLE_PRICE_SCALE;
        oracle.setPrice(price, block.timestamp);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1_000_000,
            totalSupplyShares: 1_000_000,
            totalBorrowAssets: 400_000,
            totalBorrowShares: 400_000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionBorrowAndCollateral(MARKET_ID, positionKey, 400_000, 500_000);
        h.seedModuleEncumbrance(positionKey, 202, MODULE_ID, 500_000);

        // Collateral withdraw would make position unhealthy.
        vm.expectRevert(IlmIsolatedInsufficientCollateral.selector);
        vm.prank(POSITION_OWNER);
        h.isolatedWithdrawCollateral(MARKET_ID, 400_001, positionId);

        // Borrow would also make position unhealthy.
        vm.expectRevert(IlmIsolatedInsufficientCollateral.selector);
        vm.prank(POSITION_OWNER);
        h.isolatedBorrow(MARKET_ID, 600_000, 0, positionId);
    }

    function _setDefaultMarket(IlmIsolatedTypes.IlmIsolatedMarket memory market) internal {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: 202,
            oracle: address(oracle),
            irm: address(irm),
            lltv: 8e17
        });
        h.setMarket(MARKET_ID, params, market, MODULE_ID);
    }
}

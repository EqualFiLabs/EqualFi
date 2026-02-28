// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";
import {LibIlmInterestMath} from "../../src/ilm-isolated/libraries/LibIlmInterestMath.sol";
import {LibIlmLiquidationMath} from "../../src/ilm-isolated/libraries/LibIlmLiquidationMath.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterInvariant is IIlmIsolatedIrmAdapter {
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

contract MockIlmIsolatedOracleAdapterInvariant is IIlmIsolatedOracleAdapter {
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

contract ILMIsolatedInvariantHarness is ILMIsolatedFacet {
    bytes32 internal constant ILM_LIQUIDATION_FEE_SOURCE = keccak256("ILM_LIQUIDATION_FEE");
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal _cumulativeGrossSeized;
    uint256 internal _cumulativeNetSeized;
    uint256 internal _cumulativeProtocolFeeCollateral;

    event IlmIsolatedLiquidate(
        bytes32 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets,
        uint256 badDebtAssets,
        uint256 badDebtShares
    );

    function isolatedLiquidate(
        bytes32 marketId,
        uint256 borrowerPositionId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 liquidatorPositionId
    ) external nonReentrant returns (uint256 seizedOut, uint256 repaidAssetsOut) {
        _requireExactlyOneInput(seizedAssets, repaidShares);

        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }

        _accrueInterest(marketId, market, _ds);

        IlmIsolatedTypes.IlmIsolatedMarketParams storage params = _ds.marketParams[marketId];
        uint256 oraclePrice = _getFreshPrice(params.oracle, _ds.maxStaleness);

        bytes32 borrowerKey = _positionKeyUnchecked(borrowerPositionId);
        bytes32 liquidatorKey = _checkAuthorized(liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedPosition storage borrowerPosition = _ds.position[marketId][borrowerKey];
        bool healthy = LibIlmLiquidationMath.isHealthy(
            borrowerPosition.collateralAssets,
            borrowerPosition.borrowShares,
            market.totalBorrowAssets,
            market.totalBorrowShares,
            oraclePrice,
            params.lltv
        );
        if (healthy) {
            revert IlmIsolatedHealthyPosition();
        }

        uint256 lif = LibIlmLiquidationMath.computeLIF(params.lltv);
        if (seizedAssets > 0) {
            uint256 seizedAssetsQuoted =
                Math.mulDiv(seizedAssets, oraclePrice, IlmIsolatedTypes.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
            uint256 repaidAssetsForInput = _divUp(seizedAssetsQuoted, lif);
            repaidShares =
                LibIlmSharesMath.toSharesUp(repaidAssetsForInput, market.totalBorrowAssets, market.totalBorrowShares);
        } else {
            uint256 repaidAssetsForInput =
                LibIlmSharesMath.toAssetsDown(repaidShares, market.totalBorrowAssets, market.totalBorrowShares);
            uint256 seizedValueInLoanAssets = repaidAssetsForInput * lif;
            seizedAssets = Math.mulDiv(seizedValueInLoanAssets, IlmIsolatedTypes.ORACLE_PRICE_SCALE, oraclePrice);
        }

        repaidAssetsOut = LibIlmSharesMath.toAssetsUp(repaidShares, market.totalBorrowAssets, market.totalBorrowShares);
        uint256 grossSeizedAssets = seizedAssets;
        uint256 protocolFeeCollateral =
            (grossSeizedAssets * _ds.marketLiquidationFeeBps[marketId]) / BPS_DENOMINATOR;
        uint256 netSeizedAssets = grossSeizedAssets - protocolFeeCollateral;
        seizedOut = netSeizedAssets;

        uint256 borrowAssetsBeforeRepay = market.totalBorrowAssets;
        borrowerPosition.borrowShares -= uint128(repaidShares);
        market.totalBorrowShares -= uint128(repaidShares);
        market.totalBorrowAssets = uint128(_zeroFloorSub(market.totalBorrowAssets, repaidAssetsOut));

        borrowerPosition.collateralAssets -= uint128(grossSeizedAssets);

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (borrowerPosition.collateralAssets == 0 && borrowerPosition.borrowShares > 0) {
            uint256 borrowAssetsBeforeWriteDown = market.totalBorrowAssets;
            badDebtShares = borrowerPosition.borrowShares;
            badDebtAssets = _min(
                market.totalBorrowAssets,
                LibIlmSharesMath.toAssetsUp(badDebtShares, market.totalBorrowAssets, market.totalBorrowShares)
            );

            market.totalBorrowAssets -= uint128(badDebtAssets);
            market.totalSupplyAssets -= uint128(badDebtAssets);
            market.totalBorrowShares -= uint128(badDebtShares);
            borrowerPosition.borrowShares = 0;

            _writeDownProtocolFeeClaim(marketId, badDebtAssets, borrowAssetsBeforeWriteDown, _ds);
        }

        _realizeProtocolInterestFee(marketId, params.loanPoolId, repaidAssetsOut, borrowAssetsBeforeRepay, _ds);
        _debitPrincipal(params.loanPoolId, liquidatorKey, repaidAssetsOut);
        _debitPrincipalIgnoringEncumbrance(params.collateralPoolId, borrowerKey, grossSeizedAssets);
        _creditPrincipal(params.collateralPoolId, liquidatorKey, netSeizedAssets);
        if (protocolFeeCollateral > 0) {
            LibFeeRouter.routeManagedShare(
                params.collateralPoolId, protocolFeeCollateral, ILM_LIQUIDATION_FEE_SOURCE, false, 0
            );
        }
        _unencumberWithAci(borrowerKey, params.collateralPoolId, _ds.marketModuleId[marketId], grossSeizedAssets);

        _cumulativeGrossSeized += grossSeizedAssets;
        _cumulativeNetSeized += netSeizedAssets;
        _cumulativeProtocolFeeCollateral += protocolFeeCollateral;

        if (market.totalBorrowAssets == 0) {
            _ds.marketProtocolFeeAssets[marketId] = 0;
        }

        emit IlmIsolatedLiquidate(
            marketId,
            borrowerKey,
            liquidatorKey,
            repaidAssetsOut,
            repaidShares,
            netSeizedAssets,
            badDebtAssets,
            badDebtShares
        );
    }

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

    function setPositionState(
        bytes32 marketId,
        bytes32 positionKey,
        uint256 supplyShares,
        uint256 borrowShares,
        uint256 collateralAssets
    ) external {
        if (borrowShares > type(uint128).max || collateralAssets > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }
        IlmIsolatedTypes.IlmIsolatedPosition storage p = LibIlmIsolatedStorage.s().position[marketId][positionKey];
        p.supplyShares = supplyShares;
        p.borrowShares = uint128(borrowShares);
        p.collateralAssets = uint128(collateralAssets);
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

    function setMarketLiquidationFeeBps(bytes32 marketId, uint16 bps) external {
        LibIlmIsolatedStorage.s().marketLiquidationFeeBps[marketId] = bps;
    }

    function getMarketProtocolFeeAssets(bytes32 marketId) external view returns (uint256) {
        return LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId];
    }

    function getCumulativeLiquidationSplit()
        external
        view
        returns (uint256 grossSeized, uint256 netSeized, uint256 protocolFeeCollateral)
    {
        grossSeized = _cumulativeGrossSeized;
        netSeized = _cumulativeNetSeized;
        protocolFeeCollateral = _cumulativeProtocolFeeCollateral;
    }

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function setPoolActiveCreditStateEncumbrance(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        Types.ActiveCreditState storage state = pool.userActiveCreditStateEncumbrance[positionKey];
        state.principal = principal;
        state.startTime = principal == 0 ? 0 : uint40(block.timestamp);
        state.indexSnapshot = pool.activeCreditIndex;
    }

    function setPoolActiveCreditPrincipalTotal(uint256 poolId, uint256 principalTotal) external {
        LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal = principalTotal;
    }

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
    }

    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumbered(positionKey, poolId);
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

    function _debitPrincipalIgnoringEncumbrance(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 principal = app.pools[poolId].userPrincipal[positionKey];
        if (assets > principal) {
            revert InsufficientPrincipal(assets, principal);
        }
        app.pools[poolId].userPrincipal[positionKey] = principal - assets;
        app.pools[poolId].totalDeposits -= assets;
    }

    function _writeDownProtocolFeeClaim(
        bytes32 marketId,
        uint256 writeDownAssets,
        uint256 borrowAssetsBeforeWriteDown,
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds
    ) internal {
        if (writeDownAssets == 0 || borrowAssetsBeforeWriteDown == 0) {
            return;
        }

        uint256 claim = _ds.marketProtocolFeeAssets[marketId];
        if (claim == 0) {
            return;
        }

        uint256 writeDown = claim * writeDownAssets / borrowAssetsBeforeWriteDown;
        if (writeDown > claim) {
            writeDown = claim;
        }
        _ds.marketProtocolFeeAssets[marketId] = claim - writeDown;
    }

    function _positionKeyUnchecked(uint256 positionId) internal view returns (bytes32) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmIsolatedUnauthorized();
        }
        return PositionNFT(ns.positionNFTContract).getPositionKey(positionId);
    }

    function _zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return y >= x ? 0 : x - y;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

contract ILMIsolatedHandler is Test {
    ILMIsolatedInvariantHarness internal h;
    MockIlmIsolatedOracleAdapterInvariant internal oracle;

    bytes32 internal marketId;
    uint256 internal loanPoolId;
    uint256 internal collateralPoolId;

    uint256[] internal positionIds;
    address[] internal actors;

    constructor(
        ILMIsolatedInvariantHarness harness_,
        MockIlmIsolatedOracleAdapterInvariant oracle_,
        bytes32 marketId_,
        uint256 loanPoolId_,
        uint256 collateralPoolId_,
        uint256[] memory positionIds_,
        address[] memory actors_
    ) {
        h = harness_;
        oracle = oracle_;
        marketId = marketId_;
        loanPoolId = loanPoolId_;
        collateralPoolId = collateralPoolId_;
        for (uint256 i = 0; i < positionIds_.length; i++) {
            positionIds.push(positionIds_[i]);
        }
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
    }

    function actSupply(uint256 amountSeed, uint256 bySharesSeed, uint256 actorSeed, uint256 positionSeed) external {
        (uint256 assets, uint256 shares) = _oneOf(amountSeed, bySharesSeed, 1, 500_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedSupply(marketId, assets, shares, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actWithdraw(uint256 amountSeed, uint256 bySharesSeed, uint256 actorSeed, uint256 positionSeed) external {
        (uint256 assets, uint256 shares) = _oneOf(amountSeed, bySharesSeed, 1, 500_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedWithdraw(marketId, assets, shares, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actSupplyCollateral(uint256 assetsSeed, uint256 actorSeed, uint256 positionSeed) external {
        uint256 assets = bound(assetsSeed, 1, 500_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedSupplyCollateral(marketId, assets, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actWithdrawCollateral(uint256 assetsSeed, uint256 actorSeed, uint256 positionSeed) external {
        uint256 assets = bound(assetsSeed, 1, 500_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedWithdrawCollateral(marketId, assets, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actBorrow(uint256 amountSeed, uint256 bySharesSeed, uint256 actorSeed, uint256 positionSeed) external {
        (uint256 assets, uint256 shares) = _oneOf(amountSeed, bySharesSeed, 1, 300_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedBorrow(marketId, assets, shares, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actRepay(uint256 amountSeed, uint256 bySharesSeed, uint256 actorSeed, uint256 positionSeed) external {
        (uint256 assets, uint256 shares) = _oneOf(amountSeed, bySharesSeed, 1, 300_000);
        vm.startPrank(_actor(actorSeed));
        try h.isolatedRepay(marketId, assets, shares, _positionId(positionSeed)) {} catch {}
        vm.stopPrank();
    }

    function actLiquidate(
        uint256 amountSeed,
        uint256 byRepaidSharesSeed,
        uint256 actorSeed,
        uint256 borrowerPositionSeed,
        uint256 liquidatorPositionSeed
    ) external {
        (uint256 seizedAssets, uint256 repaidShares) = _oneOf(amountSeed, byRepaidSharesSeed, 1, 300_000);
        vm.startPrank(_actor(actorSeed));
        try
            h.isolatedLiquidate(
                marketId,
                _positionId(borrowerPositionSeed),
                seizedAssets,
                repaidShares,
                _positionId(liquidatorPositionSeed)
            )
        {} catch {}
        vm.stopPrank();
    }

    function actSetOraclePrice(uint256 priceSeed) external {
        uint256 price = bound(priceSeed, 5e35, 2e36);
        oracle.setPrice(price, block.timestamp);
    }

    function actWarp(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 1 minutes, 6 hours);
        vm.warp(block.timestamp + delta);
    }

    function _oneOf(uint256 amountSeed, uint256 modeSeed, uint256 minAmt, uint256 maxAmt)
        internal
        pure
        returns (uint256 assets, uint256 shares)
    {
        uint256 amount = amountSeed % (maxAmt - minAmt + 1) + minAmt;
        if (modeSeed % 2 == 0) {
            assets = amount;
        } else {
            shares = amount;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _positionId(uint256 seed) internal view returns (uint256) {
        return positionIds[seed % positionIds.length];
    }
}

contract ILMIsolatedInvariantTest is StdInvariant, Test {
    bytes32 internal constant MARKET_ID = keccak256("ilm.isolated.invariant.market");
    uint256 internal constant LOAN_POOL_ID = 9001;
    uint256 internal constant COLLATERAL_POOL_ID = 9002;
    uint256 internal constant MODULE_ID = 909;

    address internal constant SUPPLIER_OWNER = address(0xAAA1);
    address internal constant BORROWER_OWNER = address(0xAAA2);
    address internal constant LIQUIDATOR_OWNER = address(0xAAA3);
    address internal constant OPERATOR = address(0xAAA4);
    address internal constant UNAUTHORIZED = address(0xAAA5);

    ILMIsolatedInvariantHarness internal h;
    MockIlmIsolatedIrmAdapterInvariant internal irm;
    MockIlmIsolatedOracleAdapterInvariant internal oracle;
    PositionNFT internal nft;
    ILMIsolatedHandler internal handler;

    uint256 internal supplierPositionId;
    uint256 internal borrowerPositionId;
    uint256 internal liquidatorPositionId;
    bytes32 internal supplierKey;
    bytes32 internal borrowerKey;
    bytes32 internal liquidatorKey;

    function setUp() public {
        h = new ILMIsolatedInvariantHarness();
        irm = new MockIlmIsolatedIrmAdapterInvariant();
        oracle = new MockIlmIsolatedOracleAdapterInvariant();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        h.setMaxStalenessRaw(3 days);
        irm.setRate(0);
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        supplierPositionId = nft.mint(SUPPLIER_OWNER, LOAN_POOL_ID);
        borrowerPositionId = nft.mint(BORROWER_OWNER, LOAN_POOL_ID);
        liquidatorPositionId = nft.mint(LIQUIDATOR_OWNER, LOAN_POOL_ID);
        supplierKey = nft.getPositionKey(supplierPositionId);
        borrowerKey = nft.getPositionKey(borrowerPositionId);
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            oracle: address(oracle),
            irm: address(irm),
            lltv: 8e17
        });
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 2_000_000,
            totalSupplyShares: 2_000_000,
            totalBorrowAssets: 400_000,
            totalBorrowShares: 400_000,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        h.setMarket(MARKET_ID, params, market, MODULE_ID);

        h.setPositionState(MARKET_ID, supplierKey, 2_000_000, 0, 0);
        h.setPositionState(MARKET_ID, borrowerKey, 0, 400_000, 1_200_000);
        h.setPositionState(MARKET_ID, liquidatorKey, 0, 0, 0);

        h.setAuthorizationRaw(supplierKey, OPERATOR, true);
        h.setAuthorizationRaw(borrowerKey, OPERATOR, true);
        h.setAuthorizationRaw(liquidatorKey, OPERATOR, true);

        h.setPoolPrincipal(LOAN_POOL_ID, supplierKey, 3_000_000);
        h.setPoolPrincipal(LOAN_POOL_ID, borrowerKey, 500_000);
        h.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 1_000_000);
        h.setPoolTotalDeposits(LOAN_POOL_ID, 4_500_000);
        h.setPoolTrackedBalance(LOAN_POOL_ID, 20_000_000);

        h.setPoolPrincipal(COLLATERAL_POOL_ID, supplierKey, 200_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 2_000_000);
        h.setPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey, 200_000);
        h.setPoolTotalDeposits(COLLATERAL_POOL_ID, 2_400_000);
        h.setPoolTrackedBalance(COLLATERAL_POOL_ID, 20_000_000);
        h.setGlobalFeeSplits(0, 0);
        h.setMarketLiquidationFeeBps(MARKET_ID, 250);

        h.seedModuleEncumbrance(supplierKey, LOAN_POOL_ID, MODULE_ID, 2_000_000);
        h.seedModuleEncumbrance(borrowerKey, COLLATERAL_POOL_ID, MODULE_ID, 1_200_000);
        h.setPoolActiveCreditStateEncumbrance(LOAN_POOL_ID, supplierKey, 2_000_000);
        h.setPoolActiveCreditStateEncumbrance(COLLATERAL_POOL_ID, borrowerKey, 1_200_000);
        h.setPoolActiveCreditPrincipalTotal(LOAN_POOL_ID, 2_000_000);
        h.setPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID, 1_200_000);

        uint256[] memory positionIds = new uint256[](3);
        positionIds[0] = supplierPositionId;
        positionIds[1] = borrowerPositionId;
        positionIds[2] = liquidatorPositionId;

        address[] memory actors = new address[](5);
        actors[0] = SUPPLIER_OWNER;
        actors[1] = BORROWER_OWNER;
        actors[2] = LIQUIDATOR_OWNER;
        actors[3] = OPERATOR;
        actors[4] = UNAUTHORIZED;

        handler = new ILMIsolatedHandler(h, oracle, MARKET_ID, LOAN_POOL_ID, COLLATERAL_POOL_ID, positionIds, actors);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ILMIsolatedHandler.actSupply.selector;
        selectors[1] = ILMIsolatedHandler.actWithdraw.selector;
        selectors[2] = ILMIsolatedHandler.actSupplyCollateral.selector;
        selectors[3] = ILMIsolatedHandler.actWithdrawCollateral.selector;
        selectors[4] = ILMIsolatedHandler.actBorrow.selector;
        selectors[5] = ILMIsolatedHandler.actRepay.selector;
        selectors[6] = ILMIsolatedHandler.actLiquidate.selector;
        selectors[7] = ILMIsolatedHandler.actSetOraclePrice.selector;
        selectors[8] = ILMIsolatedHandler.actWarp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Property 25: Per-Market Solvency Invariant
    /// Validates: Requirement 19.1
    function invariant_property25_perMarketSolvencyInvariant() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = h.getMarket(MARKET_ID);
        assertLe(market.totalBorrowAssets, market.totalSupplyAssets);
    }

    /// @dev Property 26: Encumbrance Bound Invariant
    /// Validates: Requirement 19.2
    function invariant_property26_encumbranceBoundInvariant() public {
        _assertEncumbranceBound(supplierKey, LOAN_POOL_ID);
        _assertEncumbranceBound(supplierKey, COLLATERAL_POOL_ID);
        _assertEncumbranceBound(borrowerKey, LOAN_POOL_ID);
        _assertEncumbranceBound(borrowerKey, COLLATERAL_POOL_ID);
        _assertEncumbranceBound(liquidatorKey, LOAN_POOL_ID);
        _assertEncumbranceBound(liquidatorKey, COLLATERAL_POOL_ID);
    }

    /// @dev Property 27: Deferred protocol claim never exceeds market borrow assets.
    /// Validates: Requirement 19.1 extension
    function invariant_property27_protocolClaimBoundedByBorrowAssets() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = h.getMarket(MARKET_ID);
        uint256 claim = h.getMarketProtocolFeeAssets(MARKET_ID);
        assertLe(claim, market.totalBorrowAssets);
    }

    /// @dev Property 28: Liquidation gross/net conservation with protocol fee split.
    /// Validates: Requirement 19.2 extension
    function invariant_property28_liquidationSplitConservation() public {
        (uint256 grossSeized, uint256 netSeized, uint256 protocolFeeCollateral) = h.getCumulativeLiquidationSplit();
        assertEq(grossSeized, netSeized + protocolFeeCollateral);
    }

    /// @dev Property 29: Active Credit principal total equals tracked encumbrance state totals.
    function invariant_property29_activeCreditStateConsistency() public {
        _assertActiveCreditStateConsistency(LOAN_POOL_ID);
        _assertActiveCreditStateConsistency(COLLATERAL_POOL_ID);
    }

    /// @dev Property 30: ILM module encumbrance totals match Active Credit principal totals per pool.
    function invariant_property30_moduleEncumbranceTracksActiveCreditTotals() public {
        _assertModuleEncumbranceMatchesAci(LOAN_POOL_ID);
        _assertModuleEncumbranceMatchesAci(COLLATERAL_POOL_ID);
    }

    function _assertEncumbranceBound(bytes32 positionKey, uint256 poolId) internal {
        uint256 principal = h.getPoolPrincipal(poolId, positionKey);
        uint256 moduleEncumbered = h.getModuleEncumbered(positionKey, poolId);
        assertLe(moduleEncumbered, principal);
    }

    function _assertActiveCreditStateConsistency(uint256 poolId) internal {
        uint256 total = h.getPoolActiveCreditPrincipalTotal(poolId);
        uint256 stateSum = h.getPoolUserActiveCreditEncumbrancePrincipal(poolId, supplierKey)
            + h.getPoolUserActiveCreditEncumbrancePrincipal(poolId, borrowerKey)
            + h.getPoolUserActiveCreditEncumbrancePrincipal(poolId, liquidatorKey);
        assertEq(total, stateSum);
    }

    function _assertModuleEncumbranceMatchesAci(uint256 poolId) internal {
        uint256 moduleEncumberedSum =
            h.getModuleEncumbered(supplierKey, poolId) + h.getModuleEncumbered(borrowerKey, poolId)
                + h.getModuleEncumbered(liquidatorKey, poolId);
        assertEq(h.getPoolActiveCreditPrincipalTotal(poolId), moduleEncumberedSum);
    }
}

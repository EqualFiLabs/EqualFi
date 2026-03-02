// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../../libraries/LibActiveCreditIndex.sol";
import {LibFeeIndex} from "../../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../../libraries/LibFeeRouter.sol";
import {LibModuleEncumbrance} from "../../libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../libraries/LibModuleRegistry.sol";
import {LibSolvencyChecks} from "../../libraries/LibSolvencyChecks.sol";
import {
    IlmTypes,
    IlmMarketNotFound,
    IlmReserveInactive,
    IlmReservePaused,
    IlmNotLiquidatable,
    IlmInvalidRiskParams,
    IlmUnauthorized,
    IlmSentinelBlocked
} from "../libraries/IlmTypes.sol";
import {LibIlmStorage} from "../libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../libraries/LibIlmIndexing.sol";
import {LibIlmLiquidation} from "../libraries/LibIlmLiquidation.sol";
import {IILMPooledLiquidationFacet} from "../interfaces/IILMPooledLiquidationFacet.sol";
import {IIlmOracleAdapter} from "../interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../interfaces/IIlmSentinelAdapter.sol";
import {ReentrancyGuardModifiers} from "../../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal, InsufficientUnencumberedPrincipal, ModuleNotFound, ModulePausedError} from "../../libraries/Errors.sol";

/// @notice Pooled-style liquidation facet for ILM markets.
contract ILMPooledLiquidationFacet is IILMPooledLiquidationFacet, ReentrancyGuardModifiers {
    bytes32 internal constant ILM_INTEREST_FEE_SOURCE = keccak256("ILM_INTEREST_FEE");
    bytes32 internal constant ILM_LIQUIDATION_FEE_SOURCE = keccak256("ILM_LIQUIDATION_FEE");
    uint256 internal constant MIN_LIQUIDATION_DUST = 1;

    event IlmLiquidation(
        uint256 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 debtLiquidated,
        uint256 scaledDebtBurned,
        uint256 collateralSeized,
        uint256 badDebtAdded
    );
    event IlmLiquidationRevenue(
        uint256 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 grossSeized,
        uint256 protocolFeeCollateral,
        uint256 netSeized
    );

    function pooledLiquidationCall(
        uint256 liquidatorPositionId,
        uint256 borrowerPositionId,
        uint256 marketId,
        uint256 debtToCover
    ) external nonReentrant returns (uint256 debtLiquidated, uint256 collateralSeized) {
        if (debtToCover == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireLiquidationAllowed(marketId, market);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);

        LibIlmIndexing.accrueMarketState(ds, marketId);
        _requireLiquidationSentinel(ds);

        bytes32 borrowerKey = _positionKey(borrowerPositionId);
        bytes32 liquidatorKey = _checkAuthorized(liquidatorPositionId, ds);
        IlmTypes.IlmPosition storage borrower = ds.positions[marketId][borrowerKey];

        uint256 collateralEncumberedBefore =
            LibModuleEncumbrance.getEncumberedForModule(borrowerKey, market.collateralPoolId, moduleId);
        uint256 priceRay = _getPrice(market.loanPoolId, market.collateralPoolId);
        uint256 hf = _computeHealthFactor(market, borrower, collateralEncumberedBefore, priceRay);
        if (hf >= IlmTypes.HF_PRECISION) {
            revert IlmNotLiquidatable(hf);
        }

        uint256 totalDebtAssets = LibIlmIndexing.fromScaledDebt(borrower.scaledDebt, market.variableBorrowIndexRay);
        uint16 closeFactorBps = LibIlmLiquidation.determineCloseFactor(hf);
        uint256 maxDebtByCloseFactor = Math.mulDiv(totalDebtAssets, closeFactorBps, IlmTypes.BPS);
        if (maxDebtByCloseFactor == 0 && totalDebtAssets > 0) {
            maxDebtByCloseFactor = totalDebtAssets;
        }

        uint256 cappedDebtToCover = debtToCover < maxDebtByCloseFactor ? debtToCover : maxDebtByCloseFactor;
        uint256 maxDebtByCollateral = 0;
        if (collateralEncumberedBefore > 0) {
            uint256 collateralValueInLoanAsset =
                Math.mulDiv(collateralEncumberedBefore, priceRay, IlmTypes.RAY);
            maxDebtByCollateral = Math.mulDiv(
                collateralValueInLoanAsset,
                IlmTypes.BPS,
                IlmTypes.BPS + uint256(market.liquidationBonusBps)
            );
        }
        if (cappedDebtToCover > maxDebtByCollateral) {
            cappedDebtToCover = maxDebtByCollateral;
        }

        uint256 scaledDebtBurned =
            LibIlmIndexing.toScaledRepay(cappedDebtToCover, market.variableBorrowIndexRay);
        if (scaledDebtBurned > borrower.scaledDebt) {
            scaledDebtBurned = borrower.scaledDebt;
        }
        if (scaledDebtBurned > market.scaledVariableDebtTotal) {
            scaledDebtBurned = market.scaledVariableDebtTotal;
        }

        if (scaledDebtBurned > 0) {
            debtLiquidated = LibIlmIndexing.fromScaledDebt(scaledDebtBurned, market.variableBorrowIndexRay);
            if (debtLiquidated > totalDebtAssets) {
                debtLiquidated = totalDebtAssets;
            }
        }

        uint256 grossSeized;
        uint256 protocolFeeCollateral;
        uint256 netSeized;
        if (debtLiquidated > 0) {
            (grossSeized, protocolFeeCollateral, netSeized) = LibIlmLiquidation.computeLiquidationAmounts(
                debtLiquidated,
                priceRay,
                market.liquidationBonusBps,
                market.liquidationProtocolFeeBps
            );
        }

        if (grossSeized > collateralEncumberedBefore) {
            grossSeized = collateralEncumberedBefore;
            protocolFeeCollateral = Math.mulDiv(grossSeized, market.liquidationProtocolFeeBps, IlmTypes.BPS);
            netSeized = grossSeized - protocolFeeCollateral;
        }
        if (scaledDebtBurned == 0 && collateralEncumberedBefore > 0) {
            revert IlmInvalidRiskParams();
        }

        uint256 remainingCollateralAfter = collateralEncumberedBefore - grossSeized;
        uint256 prospectiveScaledDebtAfter = borrower.scaledDebt - scaledDebtBurned;
        _enforceDustRule(prospectiveScaledDebtAfter, remainingCollateralAfter, market.variableBorrowIndexRay);

        uint256 borrowAssetsBeforeRepay =
            LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay);

        if (debtLiquidated > 0) {
            _debitPrincipal(market.loanPoolId, liquidatorKey, debtLiquidated);
            borrower.scaledDebt -= scaledDebtBurned;
            market.scaledVariableDebtTotal -= scaledDebtBurned;
            market.availableLiquidity += debtLiquidated;
        }

        uint256 badDebtAdded;
        if (remainingCollateralAfter == 0 && borrower.scaledDebt > 0) {
            uint256 borrowAssetsBeforeWriteDown =
                LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay);
            uint256 badScaledDebt = borrower.scaledDebt;
            if (badScaledDebt > market.scaledVariableDebtTotal) {
                badScaledDebt = market.scaledVariableDebtTotal;
            }
            badDebtAdded = LibIlmIndexing.fromScaledDebt(badScaledDebt, market.variableBorrowIndexRay);
            if (badDebtAdded > borrowAssetsBeforeWriteDown) {
                badDebtAdded = borrowAssetsBeforeWriteDown;
            }

            borrower.scaledDebt -= badScaledDebt;
            market.scaledVariableDebtTotal -= badScaledDebt;
            market.badDebt += badDebtAdded;

            _writeDownProtocolFeeClaim(marketId, badDebtAdded, borrowAssetsBeforeWriteDown, ds);
        }

        if (grossSeized > 0) {
            _debitPrincipalIgnoringEncumbrance(market.collateralPoolId, borrowerKey, grossSeized);
            _creditPrincipal(market.collateralPoolId, liquidatorKey, netSeized);
            _unencumberWithAci(borrowerKey, market.collateralPoolId, moduleId, grossSeized);
            if (protocolFeeCollateral > 0) {
                LibFeeRouter.routeManagedShare(
                    market.collateralPoolId,
                    protocolFeeCollateral,
                    ILM_LIQUIDATION_FEE_SOURCE,
                    false,
                    0
                );
            }
        }

        _realizeProtocolInterestFee(marketId, market.loanPoolId, debtLiquidated, borrowAssetsBeforeRepay, ds);
        if (LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay) == 0) {
            ds.marketProtocolFeeAssets[marketId] = 0;
        }

        collateralSeized = netSeized;
        emit IlmLiquidation(
            marketId,
            borrowerKey,
            liquidatorKey,
            debtLiquidated,
            scaledDebtBurned,
            collateralSeized,
            badDebtAdded
        );
        emit IlmLiquidationRevenue(
            marketId,
            borrowerKey,
            liquidatorKey,
            grossSeized,
            protocolFeeCollateral,
            collateralSeized
        );
    }

    function _computeHealthFactor(
        IlmTypes.IlmMarket storage market,
        IlmTypes.IlmPosition storage position,
        uint256 externalCollateralAmount,
        uint256 priceRay
    ) internal view returns (uint256 hf) {
        uint256 debtValue = LibIlmIndexing.fromScaledDebt(position.scaledDebt, market.variableBorrowIndexRay);
        if (debtValue == 0) {
            return type(uint256).max;
        }

        uint256 supplyCollateralValue = 0;
        if (position.useAsCollateral && position.scaledSupply > 0) {
            supplyCollateralValue = LibIlmIndexing.fromScaledSupply(position.scaledSupply, market.liquidityIndexRay);
        }
        uint256 externalCollateralValue = Math.mulDiv(externalCollateralAmount, priceRay, IlmTypes.RAY);
        uint256 adjustedCollateral = Math.mulDiv(
            supplyCollateralValue + externalCollateralValue,
            market.liquidationThresholdBps,
            IlmTypes.BPS
        );
        hf = Math.mulDiv(adjustedCollateral, IlmTypes.HF_PRECISION, debtValue);
    }

    function _enforceDustRule(uint256 scaledDebtAfter, uint256 collateralAfter, uint256 variableBorrowIndexRay)
        internal
        pure
    {
        if (collateralAfter > 0 && collateralAfter <= MIN_LIQUIDATION_DUST) {
            revert IlmInvalidRiskParams();
        }
        if (scaledDebtAfter > 0) {
            uint256 debtAfter = LibIlmIndexing.fromScaledDebt(scaledDebtAfter, variableBorrowIndexRay);
            if (debtAfter <= MIN_LIQUIDATION_DUST && collateralAfter > 0) {
                revert IlmInvalidRiskParams();
            }
        }
    }

    function _requireLiquidationSentinel(LibIlmStorage.IlmStorage storage ds) internal view {
        address sentinel = ds.sentinelAdapter;
        if (sentinel == address(0)) {
            return;
        }
        if (!IIlmSentinelAdapter(sentinel).isLiquidationAllowed()) {
            revert IlmSentinelBlocked();
        }
    }

    function _getPrice(uint256 loanPoolId, uint256 collateralPoolId) internal view returns (uint256 priceRay) {
        address oracleAdapter = LibIlmStorage.s().oracleAdapter;
        if (oracleAdapter == address(0)) {
            revert IlmInvalidRiskParams();
        }
        priceRay = IIlmOracleAdapter(oracleAdapter).getPrice(loanPoolId, collateralPoolId);
        if (priceRay == 0) {
            revert IlmInvalidRiskParams();
        }
    }

    function _requireLiquidationAllowed(uint256 marketId, IlmTypes.IlmMarket storage market) internal view {
        if (!market.active) {
            revert IlmReserveInactive(marketId);
        }
        if (market.paused) {
            revert IlmReservePaused(marketId);
        }
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32 key) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmUnauthorized();
        }
        key = PositionNFT(ns.positionNFTContract).getPositionKey(positionId);
    }

    function _checkAuthorized(uint256 positionId, LibIlmStorage.IlmStorage storage ds) internal view returns (bytes32 key) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmUnauthorized();
        }
        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        key = nft.getPositionKey(positionId);
        address owner = nft.ownerOf(positionId);
        if (msg.sender == owner || ds.isAuthorizedOperator[key][msg.sender]) {
            return key;
        }
        revert IlmUnauthorized();
    }

    function _creditPrincipal(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.pools[poolId].userPrincipal[positionKey] += assets;
        app.pools[poolId].totalDeposits += assets;
    }

    function _debitPrincipal(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 available = LibSolvencyChecks.calculateAvailablePrincipal(app.pools[poolId], positionKey, poolId);
        if (assets > available) {
            revert InsufficientUnencumberedPrincipal(assets, available);
        }
        app.pools[poolId].userPrincipal[positionKey] -= assets;
        app.pools[poolId].totalDeposits -= assets;
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

    function _unencumberWithAci(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
        LibActiveCreditIndex.applyEncumbranceDecrease(
            LibAppStorage.s().pools[poolId], poolId, positionKey, amount
        );
    }

    function _realizeProtocolInterestFee(
        uint256 marketId,
        uint256 loanPoolId,
        uint256 debtReductionAssets,
        uint256 borrowAssetsBefore,
        LibIlmStorage.IlmStorage storage ds
    ) internal {
        if (debtReductionAssets == 0 || borrowAssetsBefore == 0) {
            return;
        }

        uint256 claim = ds.marketProtocolFeeAssets[marketId];
        if (claim == 0) {
            return;
        }

        uint256 realized = claim * debtReductionAssets / borrowAssetsBefore;
        if (realized > claim) {
            realized = claim;
        }
        if (realized > 0) {
            ds.marketProtocolFeeAssets[marketId] = claim - realized;
            LibFeeRouter.routeManagedShare(loanPoolId, realized, ILM_INTEREST_FEE_SOURCE, false, 0);
        }
    }

    function _writeDownProtocolFeeClaim(
        uint256 marketId,
        uint256 debtWriteDownAssets,
        uint256 borrowAssetsBefore,
        LibIlmStorage.IlmStorage storage ds
    ) internal {
        if (debtWriteDownAssets == 0 || borrowAssetsBefore == 0) {
            return;
        }
        uint256 claim = ds.marketProtocolFeeAssets[marketId];
        if (claim == 0) {
            return;
        }

        uint256 writeDown = claim * debtWriteDownAssets / borrowAssetsBefore;
        if (writeDown > claim) {
            writeDown = claim;
        }
        ds.marketProtocolFeeAssets[marketId] = claim - writeDown;
    }

    function _requireModuleNotPaused(uint256 moduleId) internal view returns (uint256) {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        uint256 next = ms.nextModuleId;
        if (moduleId == 0 || next == 0 || moduleId >= next) {
            revert ModuleNotFound(moduleId);
        }
        if (ms.modules[moduleId].paused) {
            revert ModulePausedError(moduleId);
        }
        return moduleId;
    }

    function _requireMarket(uint256 marketId, LibIlmStorage.IlmStorage storage ds)
        internal
        view
        returns (IlmTypes.IlmMarket storage market)
    {
        market = ds.markets[marketId];
        if (market.lastUpdate == 0) {
            revert IlmMarketNotFound(marketId);
        }
    }
}

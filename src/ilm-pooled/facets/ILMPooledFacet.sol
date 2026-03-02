// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../../libraries/LibActiveCreditIndex.sol";
import {LibFeeIndex} from "../../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../../libraries/LibFeeRouter.sol";
import {LibActionFees} from "../../libraries/LibActionFees.sol";
import {LibModuleEncumbrance} from "../../libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../libraries/LibModuleRegistry.sol";
import {LibSolvencyChecks} from "../../libraries/LibSolvencyChecks.sol";
import {IlmTypes, IlmMarketNotFound, IlmReserveInactive, IlmReservePaused, IlmReserveFrozen, IlmSupplyCapExceeded, IlmBorrowCapExceeded, IlmInsufficientLiquidity, IlmUnsafePosition, IlmInvalidRiskParams, IlmUnauthorized, IlmSentinelBlocked} from "../libraries/IlmTypes.sol";
import {LibIlmStorage} from "../libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../libraries/LibIlmIndexing.sol";
import {IILMPooledFacet} from "../interfaces/IILMPooledFacet.sol";
import {IIlmOracleAdapter} from "../interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../interfaces/IIlmSentinelAdapter.sol";
import {ReentrancyGuardModifiers} from "../../libraries/LibReentrancyGuard.sol";
import {InsufficientUnencumberedPrincipal, ModuleNotFound, ModulePausedError} from "../../libraries/Errors.sol";

/// @notice Core ILM pooled operations (supply/withdraw/collateral; borrow/repay in later task).
contract ILMPooledFacet is IILMPooledFacet, ReentrancyGuardModifiers {
    bytes32 internal constant ILM_INTEREST_FEE_SOURCE = keccak256("ILM_INTEREST_FEE");

    event IlmSupply(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledMinted);
    event IlmWithdraw(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledBurned);
    event IlmAddCollateral(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount);
    event IlmRemoveCollateral(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount);
    event IlmBorrow(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledDebtMinted);
    event IlmRepay(uint256 indexed marketId, bytes32 indexed positionKey, uint256 amount, uint256 scaledDebtBurned);

    function pooledSupply(uint256 positionId, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireSupplyAllowed(marketId, market);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        LibIlmIndexing.accrueMarketState(ds, marketId);

        _enforceAvailablePrincipal(positionKey, market.loanPoolId, amount);
        _encumberWithAci(positionKey, market.loanPoolId, moduleId, amount);

        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];
        uint256 scaledMinted = LibIlmIndexing.toScaledSupply(amount, market.liquidityIndexRay);
        uint256 newScaledSupply = position.scaledSupply + scaledMinted;
        uint256 newScaledSupplyTotal = market.scaledSupplyTotal + scaledMinted;

        uint256 suppliedAssetsAfter = LibIlmIndexing.fromScaledSupply(newScaledSupplyTotal, market.liquidityIndexRay);
        if (market.supplyCap != 0 && suppliedAssetsAfter > market.supplyCap) {
            revert IlmSupplyCapExceeded(market.supplyCap, suppliedAssetsAfter);
        }

        position.scaledSupply = newScaledSupply;
        if (!position.useAsCollateral) {
            position.useAsCollateral = true;
        }
        market.scaledSupplyTotal = newScaledSupplyTotal;
        market.availableLiquidity += amount;

        emit IlmSupply(marketId, positionKey, amount, scaledMinted);
    }

    function pooledWithdraw(uint256 positionId, uint256 marketId, uint256 amount)
        external
        nonReentrant
        returns (uint256 withdrawn)
    {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireWithdrawAllowed(marketId, market);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        LibIlmIndexing.accrueMarketState(ds, marketId);

        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];
        uint256 scaledBurned = LibIlmIndexing.toScaledWithdraw(amount, market.liquidityIndexRay);
        if (scaledBurned > position.scaledSupply) {
            revert IlmInsufficientLiquidity(scaledBurned, position.scaledSupply);
        }
        if (scaledBurned > market.scaledSupplyTotal) {
            revert IlmInsufficientLiquidity(scaledBurned, market.scaledSupplyTotal);
        }
        if (amount > market.availableLiquidity) {
            revert IlmInsufficientLiquidity(amount, market.availableLiquidity);
        }

        uint256 newScaledSupply = position.scaledSupply - scaledBurned;
        if (position.scaledDebt > 0 && position.useAsCollateral) {
            _requireHealthyPostOperation(
                market, positionKey, moduleId, newScaledSupply, position.scaledDebt, position.useAsCollateral
            );
        }

        position.scaledSupply = newScaledSupply;
        if (newScaledSupply == 0 && position.scaledDebt == 0) {
            position.useAsCollateral = false;
        }
        market.scaledSupplyTotal -= scaledBurned;
        market.availableLiquidity -= amount;
        _unencumberWithAci(positionKey, market.loanPoolId, moduleId, amount);

        emit IlmWithdraw(marketId, positionKey, amount, scaledBurned);
        return amount;
    }

    function pooledAddCollateral(uint256 positionId, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireCollateralMutationAllowed(marketId, market);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        _enforceAvailablePrincipal(positionKey, market.collateralPoolId, amount);
        _encumberWithAci(positionKey, market.collateralPoolId, moduleId, amount);

        emit IlmAddCollateral(marketId, positionKey, amount);
    }

    function pooledRemoveCollateral(uint256 positionId, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireCollateralMutationAllowed(marketId, market);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        LibIlmIndexing.accrueMarketState(ds, marketId);

        uint256 encumbered =
            LibModuleEncumbrance.getEncumberedForModule(positionKey, market.collateralPoolId, moduleId);
        if (amount > encumbered) {
            revert IlmInsufficientLiquidity(amount, encumbered);
        }

        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];
        if (position.scaledDebt > 0 && position.useAsCollateral) {
            uint256 collateralAfter = encumbered - amount;
            _requireHealthyPostOperation(market, position.scaledSupply, position.scaledDebt, position.useAsCollateral, collateralAfter);
        }

        _unencumberWithAci(positionKey, market.collateralPoolId, moduleId, amount);
        emit IlmRemoveCollateral(marketId, positionKey, amount);
    }

    function pooledBorrow(uint256 positionId, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireSupplyAllowed(marketId, market);
        _requireBorrowSentinel(ds);
        uint256 moduleId = _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        LibIlmIndexing.accrueMarketState(ds, marketId);

        if (amount > market.availableLiquidity) {
            revert IlmInsufficientLiquidity(amount, market.availableLiquidity);
        }

        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];
        uint256 scaledDebtMinted = LibIlmIndexing.toScaledDebt(amount, market.variableBorrowIndexRay);
        uint256 newPositionScaledDebt = position.scaledDebt + scaledDebtMinted;
        uint256 newScaledVariableDebtTotal = market.scaledVariableDebtTotal + scaledDebtMinted;

        uint256 postBorrowAssets = LibIlmIndexing.fromScaledDebt(newScaledVariableDebtTotal, market.variableBorrowIndexRay);
        if (market.borrowCap != 0 && postBorrowAssets > market.borrowCap) {
            revert IlmBorrowCapExceeded(market.borrowCap, postBorrowAssets);
        }

        _requireHealthyPostOperation(
            market, positionKey, moduleId, position.scaledSupply, newPositionScaledDebt, position.useAsCollateral
        );

        position.scaledDebt = newPositionScaledDebt;
        market.scaledVariableDebtTotal = newScaledVariableDebtTotal;
        market.availableLiquidity -= amount;

        _creditPrincipal(market.loanPoolId, positionKey, amount);
        if (amount > 0) {
            LibActionFees.chargeFromUser(
                LibAppStorage.s().pools[market.loanPoolId], market.loanPoolId, LibActionFees.ACTION_BORROW, positionKey
            );
        }

        emit IlmBorrow(marketId, positionKey, amount, scaledDebtMinted);
    }

    function pooledRepay(uint256 positionId, uint256 marketId, uint256 amount)
        external
        nonReentrant
        returns (uint256 repaid)
    {
        if (amount == 0) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        _requireWithdrawAllowed(marketId, market);
        _requireModuleNotPaused(ds.marketModuleId[marketId]);
        bytes32 positionKey = _checkAuthorized(positionId, ds);

        LibIlmIndexing.accrueMarketState(ds, marketId);

        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];
        uint256 currentDebt = LibIlmIndexing.fromScaledDebt(position.scaledDebt, market.variableBorrowIndexRay);
        uint256 requestedRepay = amount < currentDebt ? amount : currentDebt;
        if (requestedRepay == 0) {
            emit IlmRepay(marketId, positionKey, 0, 0);
            return 0;
        }

        uint256 scaledDebtBurned = LibIlmIndexing.toScaledRepay(requestedRepay, market.variableBorrowIndexRay);
        if (scaledDebtBurned > position.scaledDebt) {
            scaledDebtBurned = position.scaledDebt;
        }
        if (scaledDebtBurned > market.scaledVariableDebtTotal) {
            scaledDebtBurned = market.scaledVariableDebtTotal;
        }
        if (scaledDebtBurned == 0) {
            emit IlmRepay(marketId, positionKey, 0, 0);
            return 0;
        }

        repaid = LibIlmIndexing.fromScaledDebt(scaledDebtBurned, market.variableBorrowIndexRay);
        if (repaid > currentDebt) {
            repaid = currentDebt;
        }

        uint256 borrowAssetsBefore = LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay);

        _debitPrincipal(market.loanPoolId, positionKey, repaid);
        position.scaledDebt -= scaledDebtBurned;
        if (position.scaledDebt == 0 && position.scaledSupply == 0) {
            position.useAsCollateral = false;
        }
        market.scaledVariableDebtTotal -= scaledDebtBurned;
        market.availableLiquidity += repaid;

        _realizeProtocolInterestFee(marketId, market.loanPoolId, repaid, borrowAssetsBefore, ds);

        if (repaid > 0) {
            LibActionFees.chargeFromUser(
                LibAppStorage.s().pools[market.loanPoolId], market.loanPoolId, LibActionFees.ACTION_REPAY, positionKey
            );
        }

        emit IlmRepay(marketId, positionKey, repaid, scaledDebtBurned);
        return repaid;
    }

    function _requireHealthyPostOperation(
        IlmTypes.IlmMarket storage market,
        bytes32 positionKey,
        uint256 moduleId,
        uint256 scaledSupplyAfter,
        uint256 scaledDebtAfter,
        bool useAsCollateralAfter
    ) internal view {
        uint256 externalCollateral = LibModuleEncumbrance.getEncumberedForModule(
            positionKey, market.collateralPoolId, moduleId
        );
        _requireHealthyPostOperation(market, scaledSupplyAfter, scaledDebtAfter, useAsCollateralAfter, externalCollateral);
    }

    function _requireHealthyPostOperation(
        IlmTypes.IlmMarket storage market,
        uint256 scaledSupplyAfter,
        uint256 scaledDebtAfter,
        bool useAsCollateralAfter,
        uint256 externalCollateralAmount
    ) internal view {
        uint256 debtValue = LibIlmIndexing.fromScaledDebt(scaledDebtAfter, market.variableBorrowIndexRay);
        if (debtValue == 0) {
            return;
        }

        uint256 supplyCollateralValue = 0;
        if (useAsCollateralAfter && scaledSupplyAfter > 0) {
            supplyCollateralValue = LibIlmIndexing.fromScaledSupply(scaledSupplyAfter, market.liquidityIndexRay);
        }

        uint256 externalCollateralValue = 0;
        if (externalCollateralAmount > 0) {
            uint256 priceRay = _getPrice(market.loanPoolId, market.collateralPoolId);
            externalCollateralValue = Math.mulDiv(externalCollateralAmount, priceRay, IlmTypes.RAY);
        }

        uint256 collateralValue = supplyCollateralValue + externalCollateralValue;
        uint256 adjustedCollateral = Math.mulDiv(collateralValue, market.liquidationThresholdBps, IlmTypes.BPS);
        uint256 hf = Math.mulDiv(adjustedCollateral, IlmTypes.HF_PRECISION, debtValue);
        if (hf < IlmTypes.HF_PRECISION) {
            revert IlmUnsafePosition(hf, IlmTypes.HF_PRECISION);
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

    function _requireBorrowSentinel(LibIlmStorage.IlmStorage storage ds) internal view {
        address sentinel = ds.sentinelAdapter;
        if (sentinel == address(0)) {
            return;
        }
        if (!IIlmSentinelAdapter(sentinel).isBorrowAllowed()) {
            revert IlmSentinelBlocked();
        }
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

    function _realizeProtocolInterestFee(
        uint256 marketId,
        uint256 loanPoolId,
        uint256 debtReductionAssets,
        uint256 borrowAssetsBefore,
        LibIlmStorage.IlmStorage storage ds
    ) internal {
        if (debtReductionAssets == 0 || borrowAssetsBefore == 0) {
            if (LibIlmIndexing.fromScaledDebt(ds.markets[marketId].scaledVariableDebtTotal, ds.markets[marketId].variableBorrowIndexRay) == 0) {
                ds.marketProtocolFeeAssets[marketId] = 0;
            }
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

        if (LibIlmIndexing.fromScaledDebt(ds.markets[marketId].scaledVariableDebtTotal, ds.markets[marketId].variableBorrowIndexRay) == 0) {
            ds.marketProtocolFeeAssets[marketId] = 0;
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

    function _enforceAvailablePrincipal(bytes32 positionKey, uint256 poolId, uint256 amount) internal view {
        uint256 available =
            LibSolvencyChecks.calculateAvailablePrincipal(LibAppStorage.s().pools[poolId], positionKey, poolId);
        if (amount > available) {
            revert InsufficientUnencumberedPrincipal(amount, available);
        }
    }

    function _encumberWithAci(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
        if (amount == 0 || LibModuleRegistry.s().moduleAciPaused) {
            return;
        }
        LibActiveCreditIndex.applyEncumbranceIncrease(LibAppStorage.s().pools[poolId], poolId, positionKey, amount);
    }

    function _unencumberWithAci(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
        LibActiveCreditIndex.applyEncumbranceDecrease(LibAppStorage.s().pools[poolId], poolId, positionKey, amount);
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

    function _requireSupplyAllowed(uint256 marketId, IlmTypes.IlmMarket storage market) internal view {
        if (!market.active) {
            revert IlmReserveInactive(marketId);
        }
        if (market.paused) {
            revert IlmReservePaused(marketId);
        }
        if (market.frozen) {
            revert IlmReserveFrozen(marketId);
        }
    }

    function _requireWithdrawAllowed(uint256 marketId, IlmTypes.IlmMarket storage market) internal view {
        if (!market.active) {
            revert IlmReserveInactive(marketId);
        }
        if (market.paused) {
            revert IlmReservePaused(marketId);
        }
    }

    function _requireCollateralMutationAllowed(uint256 marketId, IlmTypes.IlmMarket storage market) internal view {
        if (!market.active) {
            revert IlmReserveInactive(marketId);
        }
        if (market.paused) {
            revert IlmReservePaused(marketId);
        }
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

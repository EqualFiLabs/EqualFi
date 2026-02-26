// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibModuleEncumbrance} from "../libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import {LibEqualIndexLending} from "../libraries/LibEqualIndexLending.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Position-based borrowing against index-token pool principal.
contract EqualIndexLendingFacet is EqualIndexBaseV3, ReentrancyGuardModifiers {
    bytes32 internal constant INDEX_LENDING_FEE_SOURCE = keccak256("INDEX_LENDING_FEE");
    uint256 internal constant LENDING_MODULE_ID = uint256(keccak256("equal.index.lending.module"));

    function configureLending(
        uint256 indexId,
        uint16 ltvBps,
        uint16 originationFeeBps,
        uint40 minDuration,
        uint40 maxDuration
    ) external onlyTimelock indexExists(indexId) {
        if (ltvBps > 10_000) revert InvalidParameterRange("ltvBps");
        if (originationFeeBps > 10_000) revert InvalidParameterRange("originationFeeBps");
        if (minDuration > maxDuration) revert InvalidParameterRange("duration");

        LibEqualIndexLending.s().lendingConfigs[indexId] = LibEqualIndexLending.LendingConfig({
            ltvBps: ltvBps,
            originationFeeBps: originationFeeBps,
            minDuration: minDuration,
            maxDuration: maxDuration
        });

        emit LibEqualIndexLending.LendingConfigured(indexId, ltvBps, originationFeeBps, minDuration, maxDuration);
    }

    function borrowFromPosition(
        uint256 positionId,
        uint256 indexId,
        address asset,
        uint256 collateralUnits,
        uint256 amount,
        uint40 duration
    ) external nonReentrant indexExists(indexId) returns (uint256 loanId) {
        LibCurrency.assertZeroMsgValue();
        if (collateralUnits == 0) revert InvalidParameterRange("collateralUnits");
        if (amount == 0) revert InvalidParameterRange("amount");

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        if (duration < cfg.minDuration || duration > cfg.maxDuration) {
            revert LibEqualIndexLending.InvalidDuration(duration, cfg.minDuration, cfg.maxDuration);
        }

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);
        (bool found, uint256 bundleAmount) = _bundleAmountForAsset(idx, asset);
        if (!found) revert LibEqualIndexLending.InvalidAsset(asset);

        uint256 indexPoolId = s().indexToPoolId[indexId];
        if (indexPoolId == 0) revert PoolNotInitialized(indexPoolId);
        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, false);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage indexPool = app.pools[indexPoolId];
        uint256 availableCollateral = LibSolvencyChecks.calculateAvailablePrincipal(indexPool, positionKey, indexPoolId);
        if (availableCollateral < collateralUnits) {
            revert InsufficientUnencumberedPrincipal(collateralUnits, availableCollateral);
        }

        uint256 collateralValue = Math.mulDiv(collateralUnits, bundleAmount, LibEqualIndex.INDEX_SCALE);
        uint256 maxByLtv = Math.mulDiv(collateralValue, cfg.ltvBps, 10_000);
        if (amount > maxByLtv) {
            revert LibEqualIndexLending.LtvExceeded(amount, maxByLtv);
        }

        uint256 vaultBalance = s().vaultBalances[indexId][asset];
        if (vaultBalance < amount) revert InsufficientPoolLiquidity(amount, vaultBalance);

        uint256 lockedAfter = LibEqualIndexLending.s().lockedCollateralUnits[indexId] + collateralUnits;
        if (idx.totalUnits < lockedAfter) {
            revert LibEqualIndexLending.RedeemabilityViolation(asset, lockedAfter, idx.totalUnits);
        }

        uint256 redeemableUnits = idx.totalUnits - lockedAfter;
        uint256 requiredVaultAfter = Math.mulDiv(redeemableUnits, bundleAmount, LibEqualIndex.INDEX_SCALE);
        uint256 vaultAfter = vaultBalance - amount;
        if (vaultAfter < requiredVaultAfter) {
            revert LibEqualIndexLending.RedeemabilityViolation(asset, requiredVaultAfter, vaultAfter);
        }

        uint256 fee = Math.mulDiv(amount, cfg.originationFeeBps, 10_000);
        uint256 netAmount = amount - fee;
        uint256 assetPoolId = app.assetToPoolId[asset];
        if (assetPoolId == 0) revert NoPoolForAsset(asset);

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        loanId = ls.nextLoanId;
        ls.nextLoanId = loanId + 1;

        ls.outstandingPrincipal[indexId][asset] += amount;
        ls.lockedCollateralUnits[indexId] = lockedAfter;
        s().vaultBalances[indexId][asset] = vaultAfter;
        ls.loans[loanId] = LibEqualIndexLending.IndexLoan({
            positionKey: positionKey,
            indexId: indexId,
            borrowAsset: asset,
            collateralUnits: collateralUnits,
            principal: amount,
            maturity: uint40(block.timestamp + duration)
        });

        LibModuleEncumbrance.encumber(positionKey, indexPoolId, LENDING_MODULE_ID, collateralUnits);

        if (fee > 0) {
            Types.PoolData storage borrowPool = app.pools[assetPoolId];
            borrowPool.trackedBalance += fee;
            LibFeeRouter.routeManagedShare(assetPoolId, fee, INDEX_LENDING_FEE_SOURCE, true, 0);
        }

        if (netAmount > 0) {
            if (LibCurrency.isNative(asset)) {
                app.nativeTrackedTotal -= netAmount;
            }
            LibCurrency.transfer(asset, msg.sender, netAmount);
        }

        emit LibEqualIndexLending.LoanCreated(
            loanId, positionKey, indexId, asset, collateralUnits, amount, uint40(block.timestamp + duration), fee
        );
    }

    function repayFromPosition(uint256 positionId, uint256 loanId) external payable nonReentrant {
        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.positionKey != positionKey) {
            revert LibEqualIndexLending.PositionMismatch(loan.positionKey, positionKey);
        }

        LibCurrency.assertMsgValue(loan.borrowAsset, loan.principal);
        LibCurrency.pullAtLeast(loan.borrowAsset, msg.sender, loan.principal, loan.principal);

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        s().vaultBalances[loan.indexId][loan.borrowAsset] += loan.principal;
        ls.outstandingPrincipal[loan.indexId][loan.borrowAsset] -= loan.principal;
        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;

        uint256 indexPoolId = s().indexToPoolId[loan.indexId];
        LibModuleEncumbrance.unencumber(positionKey, indexPoolId, LENDING_MODULE_ID, loan.collateralUnits);

        uint256 repaidPrincipal = loan.principal;
        uint256 repaidIndexId = loan.indexId;
        address repaidAsset = loan.borrowAsset;
        delete ls.loans[loanId];

        emit LibEqualIndexLending.LoanRepaid(loanId, repaidIndexId, repaidAsset, repaidPrincipal);
    }

    function extendFromPosition(uint256 positionId, uint256 loanId, uint40 addedDuration) external payable nonReentrant {
        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.positionKey != positionKey) {
            revert LibEqualIndexLending.PositionMismatch(loan.positionKey, positionKey);
        }
        if (block.timestamp > loan.maturity) {
            revert LibEqualIndexLending.LoanExpired(loanId, loan.maturity);
        }

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(loan.indexId);
        uint256 newMaturity = uint256(loan.maturity) + addedDuration;
        uint256 maxAllowed = block.timestamp + cfg.maxDuration;
        if (newMaturity > maxAllowed) {
            revert LibEqualIndexLending.MaxDurationExceeded(uint40(newMaturity), uint40(maxAllowed));
        }

        uint256 fee = Math.mulDiv(loan.principal, cfg.originationFeeBps, 10_000);
        if (fee > 0) {
            LibCurrency.assertMsgValue(loan.borrowAsset, fee);
            LibCurrency.pullAtLeast(loan.borrowAsset, msg.sender, fee, fee);

            uint256 poolId = LibAppStorage.s().assetToPoolId[loan.borrowAsset];
            if (poolId == 0) revert NoPoolForAsset(loan.borrowAsset);
            Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
            pool.trackedBalance += fee;
            LibFeeRouter.routeManagedShare(poolId, fee, INDEX_LENDING_FEE_SOURCE, true, 0);
        } else {
            LibCurrency.assertMsgValue(loan.borrowAsset, 0);
        }

        loan.maturity = uint40(newMaturity);
        emit LibEqualIndexLending.LoanExtended(loanId, loan.maturity, fee);
    }

    function recoverExpired(uint256 loanId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        if (block.timestamp <= loan.maturity) {
            revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        ls.outstandingPrincipal[loan.indexId][loan.borrowAsset] -= loan.principal;
        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;

        Index storage idx = s().indexes[loan.indexId];
        idx.totalUnits -= loan.collateralUnits;
        IndexToken(idx.token).burnIndexUnits(address(this), loan.collateralUnits);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 indexPoolId = s().indexToPoolId[loan.indexId];
        Types.PoolData storage indexPool = app.pools[indexPoolId];
        LibFeeIndex.settle(indexPoolId, loan.positionKey);

        uint256 principalBefore = indexPool.userPrincipal[loan.positionKey];
        if (principalBefore < loan.collateralUnits) {
            revert InsufficientPrincipal(loan.collateralUnits, principalBefore);
        }
        uint256 principalAfter = principalBefore - loan.collateralUnits;
        indexPool.userPrincipal[loan.positionKey] = principalAfter;
        indexPool.totalDeposits -= loan.collateralUnits;
        if (indexPool.trackedBalance < loan.collateralUnits) {
            revert InsufficientPrincipal(loan.collateralUnits, indexPool.trackedBalance);
        }
        indexPool.trackedBalance -= loan.collateralUnits;
        if (principalBefore > 0 && principalAfter == 0 && indexPool.userCount > 0) {
            indexPool.userCount -= 1;
        }
        indexPool.userFeeIndex[loan.positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[loan.positionKey] = indexPool.maintenanceIndex;

        LibModuleEncumbrance.unencumber(loan.positionKey, indexPoolId, LENDING_MODULE_ID, loan.collateralUnits);

        uint256 recoveredIndexId = loan.indexId;
        address recoveredAsset = loan.borrowAsset;
        uint256 recoveredCollateral = loan.collateralUnits;
        uint256 recoveredPrincipal = loan.principal;
        delete ls.loans[loanId];

        emit LibEqualIndexLending.LoanRecovered(
            loanId, recoveredIndexId, recoveredAsset, recoveredCollateral, recoveredPrincipal
        );
    }

    function getLoan(uint256 loanId) external view returns (LibEqualIndexLending.IndexLoan memory) {
        return LibEqualIndexLending.s().loans[loanId];
    }

    function getOutstandingPrincipal(uint256 indexId, address asset) external view indexExists(indexId) returns (uint256) {
        return LibEqualIndexLending.s().outstandingPrincipal[indexId][asset];
    }

    function getLockedCollateralUnits(uint256 indexId) external view indexExists(indexId) returns (uint256) {
        return LibEqualIndexLending.s().lockedCollateralUnits[indexId];
    }

    function getLendingConfig(uint256 indexId)
        external
        view
        indexExists(indexId)
        returns (LibEqualIndexLending.LendingConfig memory)
    {
        return LibEqualIndexLending.s().lendingConfigs[indexId];
    }

    function economicBalance(uint256 indexId, address asset) external view indexExists(indexId) returns (uint256) {
        return LibEqualIndexLending.getEconomicBalance(indexId, asset, s().vaultBalances[indexId][asset]);
    }

    function maxBorrowable(uint256 indexId, address asset, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (uint256)
    {
        if (collateralUnits == 0) return 0;
        Index storage idx = s().indexes[indexId];
        (bool found, uint256 bundleAmount) = _bundleAmountForAsset(idx, asset);
        if (!found) revert LibEqualIndexLending.InvalidAsset(asset);

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        uint256 collateralValue = Math.mulDiv(collateralUnits, bundleAmount, LibEqualIndex.INDEX_SCALE);
        return Math.mulDiv(collateralValue, cfg.ltvBps, 10_000);
    }

    function lendingModuleId() external pure returns (uint256) {
        return LENDING_MODULE_ID;
    }

    function _bundleAmountForAsset(Index storage idx, address asset) private view returns (bool found, uint256 amount) {
        uint256 len = idx.assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (idx.assets[i] == asset) {
                return (true, idx.bundleAmounts[i]);
            }
        }
        return (false, 0);
    }

    function _configuredLending(uint256 indexId) private view returns (LibEqualIndexLending.LendingConfig memory cfg) {
        cfg = LibEqualIndexLending.s().lendingConfigs[indexId];
        if (
            cfg.ltvBps == 0 && cfg.originationFeeBps == 0 && cfg.minDuration == 0 && cfg.maxDuration == 0
        ) {
            revert LibEqualIndexLending.LendingNotConfigured(indexId);
        }
    }

    function _requireLoan(uint256 loanId) private view returns (LibEqualIndexLending.IndexLoan storage loan) {
        loan = LibEqualIndexLending.s().loans[loanId];
        if (loan.principal == 0) revert LibEqualIndexLending.LoanNotFound(loanId);
    }
}

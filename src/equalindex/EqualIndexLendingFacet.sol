// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
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
/// @dev Borrowing is basket-based: collateral index units mint a proportional debt basket.
contract EqualIndexLendingFacet is EqualIndexBaseV3, ReentrancyGuardModifiers {
    uint256 internal constant LENDING_MODULE_ID = uint256(keccak256("equal.index.lending.module"));

    function configureLending(
        uint256 indexId,
        uint16 ltvBps,
        uint16 originationFeeBps,
        uint40 minDuration,
        uint40 maxDuration
    ) external onlyTimelock indexExists(indexId) {
        if (ltvBps != 10_000) revert InvalidParameterRange("ltvBps");
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

    function configureBorrowFeeTiers(
        uint256 indexId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external onlyTimelock indexExists(indexId) {
        uint256 len = minCollateralUnits.length;
        if (len == 0 || len != flatFeeNative.length) revert InvalidArrayLength();

        uint256 prevMin;
        for (uint256 i = 0; i < len; i++) {
            uint256 minUnits = minCollateralUnits[i];
            if (minUnits == 0 || minUnits % LibEqualIndex.INDEX_SCALE != 0) {
                revert InvalidParameterRange("tierCollateralUnitsWhole");
            }
            if (i > 0 && minUnits <= prevMin) revert InvalidParameterRange("tierOrder");
            prevMin = minUnits;
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        delete ls.borrowFeeTiers[indexId];
        for (uint256 i = 0; i < len; i++) {
            ls.borrowFeeTiers[indexId].push(
                LibEqualIndexLending.BorrowFeeTier({
                    minCollateralUnits: minCollateralUnits[i],
                    flatFeeNative: flatFeeNative[i]
                })
            );
        }

        emit LibEqualIndexLending.BorrowFeeTiersConfigured(indexId, minCollateralUnits, flatFeeNative);
    }

    function borrowFromPosition(uint256 positionId, uint256 indexId, uint256 collateralUnits, uint40 duration)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256 loanId)
    {
        if (collateralUnits == 0) revert InvalidParameterRange("collateralUnits");
        if (collateralUnits % LibEqualIndex.INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        if (duration < cfg.minDuration || duration > cfg.maxDuration) {
            revert LibEqualIndexLending.InvalidDuration(duration, cfg.minDuration, cfg.maxDuration);
        }
        uint256 flatFeeNative = _borrowFlatFee(indexId, collateralUnits);
        _collectFlatNativeFee(flatFeeNative);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 indexPoolId = s().indexToPoolId[indexId];
        if (indexPoolId == 0) revert PoolNotInitialized(indexPoolId);
        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, false);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage indexPool = app.pools[indexPoolId];
        uint256 availableCollateral = LibSolvencyChecks.calculateAvailablePrincipal(indexPool, positionKey, indexPoolId);
        if (availableCollateral < collateralUnits) {
            revert InsufficientUnencumberedPrincipal(collateralUnits, availableCollateral);
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 lockedAfter = ls.lockedCollateralUnits[indexId] + collateralUnits;
        if (idx.totalUnits < lockedAfter) {
            revert LibEqualIndexLending.RedeemabilityViolation(address(0), lockedAfter, idx.totalUnits);
        }
        uint256 redeemableUnits = idx.totalUnits - lockedAfter;

        (address[] memory assets, uint256[] memory principals) = _loanPrincipals(idx, collateralUnits, cfg.ltvBps);
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            uint256 vaultBalance = s().vaultBalances[indexId][asset];
            if (vaultBalance < principal) revert InsufficientPoolLiquidity(principal, vaultBalance);

            uint256 requiredVaultAfter = Math.mulDiv(redeemableUnits, idx.bundleAmounts[i], LibEqualIndex.INDEX_SCALE);
            uint256 vaultAfter = vaultBalance - principal;
            if (vaultAfter < requiredVaultAfter) {
                revert LibEqualIndexLending.RedeemabilityViolation(asset, requiredVaultAfter, vaultAfter);
            }
        }

        loanId = ls.nextLoanId;
        ls.nextLoanId = loanId + 1;
        ls.lockedCollateralUnits[indexId] = lockedAfter;
        ls.loans[loanId] = LibEqualIndexLending.IndexLoan({
            positionKey: positionKey,
            indexId: indexId,
            collateralUnits: collateralUnits,
            ltvBps: cfg.ltvBps,
            maturity: uint40(block.timestamp + duration)
        });
        LibModuleEncumbrance.encumber(positionKey, indexPoolId, LENDING_MODULE_ID, collateralUnits);

        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            uint256 assetPoolId = app.assetToPoolId[asset];
            if (assetPoolId == 0) revert NoPoolForAsset(asset);

            ls.outstandingPrincipal[indexId][asset] += principal;
            s().vaultBalances[indexId][asset] -= principal;

            if (principal > 0) {
                if (LibCurrency.isNative(asset)) {
                    app.nativeTrackedTotal -= principal;
                }
                LibCurrency.transfer(asset, msg.sender, principal);
            }
            emit LibEqualIndexLending.LoanAssetDelta(loanId, asset, principal, 0, true);
        }

        emit LibEqualIndexLending.LoanCreated(
            loanId, positionKey, indexId, collateralUnits, cfg.ltvBps, uint40(block.timestamp + duration)
        );
        emit LibEqualIndexLending.BorrowFlatFeePaid(loanId, indexId, collateralUnits, flatFeeNative);
    }

    function repayFromPosition(uint256 positionId, uint256 loanId) external payable nonReentrant {
        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.positionKey != positionKey) {
            revert LibEqualIndexLending.PositionMismatch(loan.positionKey, positionKey);
        }

        Index storage idx = s().indexes[loan.indexId];
        (address[] memory assets, uint256[] memory principals) = _loanPrincipals(idx, loan.collateralUnits, loan.ltvBps);
        uint256 nativeDue = _sumForNative(assets, principals);

        LibCurrency.assertMsgValue(address(0), nativeDue);
        if (nativeDue > 0) {
            LibCurrency.pullAtLeast(address(0), msg.sender, nativeDue, nativeDue);
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            if (!LibCurrency.isNative(asset)) {
                LibCurrency.pullAtLeast(asset, msg.sender, principal, principal);
            }
            s().vaultBalances[loan.indexId][asset] += principal;
            ls.outstandingPrincipal[loan.indexId][asset] -= principal;
            emit LibEqualIndexLending.LoanAssetDelta(loanId, asset, principal, 0, false);
        }

        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;

        uint256 indexPoolId = s().indexToPoolId[loan.indexId];
        LibModuleEncumbrance.unencumber(positionKey, indexPoolId, LENDING_MODULE_ID, loan.collateralUnits);

        uint256 repaidIndexId = loan.indexId;
        delete ls.loans[loanId];
        emit LibEqualIndexLending.LoanRepaid(loanId, repaidIndexId);
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

        uint256 flatFeeNative = _borrowFlatFee(loan.indexId, loan.collateralUnits);
        _collectFlatNativeFee(flatFeeNative);

        loan.maturity = uint40(newMaturity);
        emit LibEqualIndexLending.LoanExtended(loanId, loan.maturity, flatFeeNative);
        emit LibEqualIndexLending.LoanExtendFlatFeePaid(
            loanId,
            loan.indexId,
            loan.collateralUnits,
            addedDuration,
            flatFeeNative
        );
    }

    function recoverExpired(uint256 loanId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        if (block.timestamp <= loan.maturity) {
            revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
        }

        Index storage idx = s().indexes[loan.indexId];
        (address[] memory assets, uint256[] memory principals) = _loanPrincipals(idx, loan.collateralUnits, loan.ltvBps);
        uint256 len = assets.length;

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 writtenOffPrincipalTotal;
        for (uint256 i = 0; i < len; i++) {
            uint256 principal = principals[i];
            ls.outstandingPrincipal[loan.indexId][assets[i]] -= principal;
            writtenOffPrincipalTotal += principal;
            emit LibEqualIndexLending.LoanAssetDelta(loanId, assets[i], principal, 0, false);
        }
        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;

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
        uint256 recoveredCollateral = loan.collateralUnits;
        delete ls.loans[loanId];

        emit LibEqualIndexLending.LoanRecovered(
            loanId, recoveredIndexId, recoveredCollateral, writtenOffPrincipalTotal
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
        if (collateralUnits % LibEqualIndex.INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        Index storage idx = s().indexes[indexId];
        (bool found, uint256 bundleAmount) = _bundleAmountForAsset(idx, asset);
        if (!found) revert LibEqualIndexLending.InvalidAsset(asset);

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        uint256 collateralValue = Math.mulDiv(collateralUnits, bundleAmount, LibEqualIndex.INDEX_SCALE);
        return Math.mulDiv(collateralValue, cfg.ltvBps, 10_000);
    }

    function quoteBorrowBasket(uint256 indexId, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (address[] memory assets, uint256[] memory principals)
    {
        if (collateralUnits == 0) return (new address[](0), new uint256[](0));
        if (collateralUnits % LibEqualIndex.INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        return _loanPrincipals(s().indexes[indexId], collateralUnits, cfg.ltvBps);
    }

    function quoteBorrowFee(uint256 indexId, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (uint256)
    {
        if (collateralUnits == 0) return 0;
        if (collateralUnits % LibEqualIndex.INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        return _borrowFlatFee(indexId, collateralUnits);
    }

    function getBorrowFeeTiers(uint256 indexId)
        external
        view
        indexExists(indexId)
        returns (uint256[] memory minCollateralUnits, uint256[] memory flatFeeNative)
    {
        LibEqualIndexLending.BorrowFeeTier[] storage tiers = LibEqualIndexLending.s().borrowFeeTiers[indexId];
        uint256 len = tiers.length;
        minCollateralUnits = new uint256[](len);
        flatFeeNative = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            minCollateralUnits[i] = tiers[i].minCollateralUnits;
            flatFeeNative[i] = tiers[i].flatFeeNative;
        }
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
        if (loan.collateralUnits == 0) revert LibEqualIndexLending.LoanNotFound(loanId);
    }

    function _loanPrincipals(Index storage idx, uint256 collateralUnits, uint16 ltvBps)
        private
        view
        returns (address[] memory assets, uint256[] memory principals)
    {
        assets = idx.assets;
        uint256 len = assets.length;
        principals = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 collateralValue = Math.mulDiv(collateralUnits, idx.bundleAmounts[i], LibEqualIndex.INDEX_SCALE);
            principals[i] = Math.mulDiv(collateralValue, ltvBps, 10_000);
        }
    }

    function _borrowFlatFee(uint256 indexId, uint256 collateralUnits) private view returns (uint256 feeNative) {
        LibEqualIndexLending.BorrowFeeTier[] storage tiers = LibEqualIndexLending.s().borrowFeeTiers[indexId];
        uint256 len = tiers.length;
        if (len == 0) return 0;
        if (collateralUnits < tiers[0].minCollateralUnits) {
            revert InvalidParameterRange("collateralUnitsBelowFeeTier");
        }
        for (uint256 i = len; i > 0; i--) {
            LibEqualIndexLending.BorrowFeeTier storage tier = tiers[i - 1];
            if (collateralUnits >= tier.minCollateralUnits) {
                return tier.flatFeeNative;
            }
        }
        return 0;
    }

    function _collectFlatNativeFee(uint256 feeNative) private {
        if (feeNative == 0) {
            LibCurrency.assertZeroMsgValue();
            return;
        }
        if (msg.value != feeNative) {
            revert LibEqualIndexLending.FlatFeePaymentMismatch(feeNative, msg.value);
        }
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0)) revert LibEqualIndexLending.FlatFeeTreasuryNotSet();
        LibCurrency.transfer(address(0), treasury, feeNative);
    }

    function _sumForNative(address[] memory assets, uint256[] memory amounts) private pure returns (uint256 sum) {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (LibCurrency.isNative(assets[i])) {
                sum += amounts[i];
            }
        }
    }
}

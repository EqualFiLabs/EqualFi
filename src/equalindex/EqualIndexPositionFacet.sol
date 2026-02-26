// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexToken} from "./IndexToken.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibIndexEncumbrance} from "../libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibPoints} from "../libraries/LibPoints.sol";
import {LibEqualIndexLending} from "../libraries/LibEqualIndexLending.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Position-based index mint operations.
contract EqualIndexPositionFacet is EqualIndexBaseV3, ReentrancyGuardModifiers {
    bytes32 internal constant INDEX_FEE_SOURCE = keccak256("INDEX_FEE");

    /// @notice Mint index tokens from position principal, priced pro-rata against
    /// current total assets (vault + fee pot).
    function mintFromPosition(
        uint256 positionId,
        uint256 indexId,
        uint256 units
    ) external nonReentrant indexExists(indexId) returns (uint256 minted) {
        if (units == 0 || units % LibEqualIndex.INDEX_SCALE != 0) revert InvalidUnits();

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 len = idx.assets.length;
        uint256[] memory required = new uint256[](len);
        uint256[] memory fees = new uint256[](len);

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint16 poolFeeShareBps = _poolFeeShareBps();
        uint256 totalSupply = idx.totalUnits;

        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            uint256 poolId = store.assetToPoolId[asset];
            if (poolId == 0) revert NoPoolForAsset(asset);
            if (!LibPoolMembership.isMember(positionKey, poolId)) {
                revert NotMemberOfRequiredPool(positionKey, poolId);
            }

            uint256 vaultIn;
            uint256 potBuyIn;
            if (totalSupply == 0) {
                vaultIn = Math.mulDiv(idx.bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            } else {
                uint256 economicBal =
                    LibEqualIndexLending.getEconomicBalance(indexId, asset, s().vaultBalances[indexId][asset]);
                vaultIn = Math.mulDiv(economicBal, units, totalSupply, Math.Rounding.Ceil);
                potBuyIn = Math.mulDiv(s().feePots[indexId][asset], units, totalSupply, Math.Rounding.Ceil);
            }
            uint256 grossIn = vaultIn + potBuyIn;
            uint256 fee = Math.mulDiv(grossIn, idx.mintFeeBps[i], 10_000, Math.Rounding.Ceil);
            uint256 total = grossIn + fee;

            Types.PoolData storage pool = store.pools[poolId];
            uint256 available = LibSolvencyChecks.calculateAvailablePrincipal(pool, positionKey, poolId);
            if (available < total) {
                revert InsufficientUnencumberedPrincipal(total, available);
            }

            required[i] = grossIn;
            fees[i] = fee;

            LibIndexEncumbrance.encumber(positionKey, poolId, indexId, vaultIn);
            s().vaultBalances[indexId][asset] += vaultIn;

            if (potBuyIn > 0 || fee > 0) {
                LibFeeIndex.settle(poolId, positionKey);
                uint256 principal = pool.userPrincipal[positionKey];
                uint256 principalDeduction = potBuyIn + fee;
                if (principal < principalDeduction) {
                    revert InsufficientPrincipal(principalDeduction, principal);
                }
                pool.userPrincipal[positionKey] = principal - principalDeduction;
                pool.totalDeposits -= principalDeduction;
            }

            if (potBuyIn > 0) {
                if (pool.trackedBalance < potBuyIn) {
                    revert InsufficientPoolLiquidity(potBuyIn, pool.trackedBalance);
                }
                pool.trackedBalance -= potBuyIn;
                s().feePots[indexId][asset] += potBuyIn;
            }

            if (fee > 0) {
                uint256 poolShare = Math.mulDiv(fee, poolFeeShareBps, 10_000);
                uint256 potShare = fee - poolShare;
                if (potShare > 0) {
                    if (pool.trackedBalance < potShare) {
                        revert InsufficientPoolLiquidity(potShare, pool.trackedBalance);
                    }
                    pool.trackedBalance -= potShare;
                    s().feePots[indexId][asset] += potShare;
                }
                if (poolShare > 0) {
                    LibFeeRouter.routeManagedShare(poolId, poolShare, INDEX_FEE_SOURCE, true, 0);
                }
            }
        }

        minted = units;
        idx.totalUnits += minted;
        IndexToken(idx.token).mintIndexUnits(address(this), minted);
        IndexToken(idx.token).recordMintDetails(msg.sender, minted, idx.assets, required, fees, 0);

        uint256 indexPoolId = s().indexToPoolId[indexId];
        if (indexPoolId == 0) revert PoolNotInitialized(indexPoolId);

        Types.PoolData storage indexPool = store.pools[indexPoolId];
        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, true);
        LibFeeIndex.settle(indexPoolId, positionKey);

        uint256 currentPrincipal = indexPool.userPrincipal[positionKey];
        bool isNewUser = currentPrincipal == 0;
        if (isNewUser) {
            uint256 maxUsers = indexPool.poolConfig.maxUserCount;
            if (maxUsers > 0 && indexPool.userCount >= maxUsers) {
                revert MaxUserCountExceeded(maxUsers);
            }
        }

        uint256 newPrincipal = currentPrincipal + minted;
        if (indexPool.poolConfig.isCapped) {
            uint256 cap = indexPool.poolConfig.depositCap;
            if (cap > 0 && newPrincipal > cap) {
                revert DepositCapExceeded(newPrincipal, cap);
            }
        }

        indexPool.userPrincipal[positionKey] = newPrincipal;
        indexPool.totalDeposits += minted;
        indexPool.trackedBalance += minted;
        if (isNewUser && minted > 0) {
            indexPool.userCount += 1;
        }
        indexPool.userFeeIndex[positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[positionKey] = indexPool.maintenanceIndex;
        LibPoints.accrueToKey(msg.sender, positionKey, LibPoints.ACTION_INDEX_MINT_POSITION);
    }

    /// @notice Burn index tokens and unencumber underlying assets.
    function burnFromPosition(
        uint256 positionId,
        uint256 indexId,
        uint256 units
    ) external nonReentrant indexExists(indexId) returns (uint256[] memory assetsOut) {
        if (units == 0 || units % LibEqualIndex.INDEX_SCALE != 0) revert InvalidUnits();

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 totalSupply = idx.totalUnits;
        if (units > totalSupply) revert InvalidUnits();

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 indexPoolId = s().indexToPoolId[indexId];
        Types.PoolData storage indexPool = store.pools[indexPoolId];
        if (!indexPool.initialized) revert PoolNotInitialized(indexPoolId);

        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, true);
        LibFeeIndex.settle(indexPoolId, positionKey);
        uint256 positionIndexBalance = indexPool.userPrincipal[positionKey];
        if (units > positionIndexBalance) {
            revert InsufficientIndexTokens(units, positionIndexBalance);
        }

        uint256 len = idx.assets.length;
        assetsOut = new uint256[](len);
        uint256[] memory feeAmounts = new uint256[](len);
        uint16 poolFeeShareBps = _poolFeeShareBps();

        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            uint256 poolId = store.assetToPoolId[asset];
            if (poolId == 0) revert NoPoolForAsset(asset);

            LibPoolMembership._ensurePoolMembership(positionKey, poolId, true);
            Types.PoolData storage pool = store.pools[poolId];

            uint256 vaultBalance = s().vaultBalances[indexId][asset];
            uint256 potBalance = s().feePots[indexId][asset];
            uint256 bundleOut = Math.mulDiv(idx.bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            if (vaultBalance < bundleOut) {
                revert InsufficientPoolLiquidity(bundleOut, vaultBalance);
            }
            uint256 potShare = Math.mulDiv(potBalance, units, totalSupply);
            uint256 gross = bundleOut + potShare;
            uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);

            uint256 poolShare = Math.mulDiv(burnFee, poolFeeShareBps, 10_000);
            uint256 potFee = burnFee - poolShare;

            s().vaultBalances[indexId][asset] = vaultBalance - bundleOut;
            s().feePots[indexId][asset] = potBalance - potShare + potFee;
            if (poolShare > 0) {
                pool.trackedBalance += poolShare;
                LibFeeRouter.routeManagedShare(poolId, poolShare, INDEX_FEE_SOURCE, true, 0);
            }

            uint256 payout = gross - burnFee;
            assetsOut[i] = payout;
            feeAmounts[i] = burnFee;

            if (gross > 0) {
                uint256 navOut = Math.mulDiv(payout, bundleOut, gross);
                uint256 potOut = payout - navOut;

                if (navOut > 0) {
                    LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, navOut);
                }
                if (potOut > 0) {
                    LibFeeIndex.settle(poolId, positionKey);
                    uint256 currentPrincipal = pool.userPrincipal[positionKey];
                    bool isNewUser = currentPrincipal == 0;
                    if (isNewUser) {
                        uint256 maxUsers = pool.poolConfig.maxUserCount;
                        if (maxUsers > 0 && pool.userCount >= maxUsers) {
                            revert MaxUserCountExceeded(maxUsers);
                        }
                    }
                    pool.userPrincipal[positionKey] = currentPrincipal + potOut;
                    pool.totalDeposits += potOut;
                    pool.trackedBalance += potOut;
                    // potOut is a reclassification from index fee pot into pool principal.
                    // Native backing is already counted in nativeTrackedTotal, so no global adjustment here.
                    if (isNewUser && potOut > 0) {
                        pool.userCount += 1;
                    }
                    pool.userFeeIndex[positionKey] = pool.feeIndex;
                    pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
                }
            }
        }

        idx.totalUnits = totalSupply - units;
        IndexToken(idx.token).burnIndexUnits(address(this), units);
        IndexToken(idx.token).recordBurnDetails(msg.sender, units, idx.assets, assetsOut, feeAmounts, 0);

        uint256 newPrincipal = positionIndexBalance - units;
        indexPool.userPrincipal[positionKey] = newPrincipal;
        indexPool.totalDeposits -= units;
        if (indexPool.trackedBalance < units) {
            revert InsufficientPrincipal(units, indexPool.trackedBalance);
        }
        indexPool.trackedBalance -= units;
        if (positionIndexBalance > 0 && newPrincipal == 0 && indexPool.userCount > 0) {
            indexPool.userCount -= 1;
        }
        indexPool.userFeeIndex[positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[positionKey] = indexPool.maintenanceIndex;
        LibPoints.accrueToKey(msg.sender, positionKey, LibPoints.ACTION_INDEX_BURN_POSITION);
    }
}

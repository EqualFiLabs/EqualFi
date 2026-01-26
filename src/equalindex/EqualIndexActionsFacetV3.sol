// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {Types} from "../libraries/Types.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {EqualIndexBaseV3, IEqualIndexFlashReceiver} from "./EqualIndexBaseV3.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/Errors.sol";

/// @notice Core mint/burn/flash operations for EqualIndex V3.
contract EqualIndexActionsFacetV3 is EqualIndexBaseV3, ReentrancyGuardModifiers {
    bytes32 internal constant INDEX_FEE_SOURCE = keccak256("INDEX_FEE");

    /// @notice Mint index tokens. `units` must be a multiple of 1e18 (INDEX_SCALE).
    function mint(uint256 indexId, uint256 units, address to)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256 minted)
    {
        if (units == 0 || units % LibEqualIndex.INDEX_SCALE != 0) revert InvalidUnits();
        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 len = idx.assets.length;
        uint256 nativeTotal;
        bool hasNative;
        uint256[] memory required = new uint256[](len);
        uint256[] memory fees = new uint256[](len);
        uint256[] memory vaultCredits = new uint256[](len);
        uint256[] memory vaultBalancesBefore = new uint256[](len);
        uint16 feeIndexShareBps = _mintBurnFeeIndexShareBps();

        for (uint256 i = 0; i < len; i++) {
            uint256 need = Math.mulDiv(idx.bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            uint256 fee = Math.mulDiv(need, idx.mintFeeBps[i], 10_000);
            uint256 total = need + fee;
            address asset = idx.assets[i];
            vaultBalancesBefore[i] = s().vaultBalances[indexId][asset];
            if (LibCurrency.isNative(asset)) {
                hasNative = true;
                nativeTotal += total;
            } else {
                uint256 received = LibCurrency.pull(asset, msg.sender, total);
                if (received < total) revert InvalidBundleDefinition();
            }
            required[i] = need;
            fees[i] = fee;
            vaultCredits[i] = need;
        }
        if (hasNative) {
            _pullNativeMint(nativeTotal);
        } else {
            LibCurrency.assertZeroMsgValue();
        }
        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            uint256 need = required[i];
            s().vaultBalances[indexId][asset] = vaultBalancesBefore[i] + need;
            _distributeIndexFee(indexId, idx, asset, fees[i], feeIndexShareBps);
        }

        uint256 totalSupplyBefore = idx.totalUnits;
        if (totalSupplyBefore == 0) {
            minted = units;
        } else {
            minted = type(uint256).max;
            for (uint256 i = 0; i < len; i++) {
                uint256 balanceBefore = vaultBalancesBefore[i];
                require(balanceBefore > 0, "EqualIndex: zero NAV asset");
                uint256 mintedForAsset = (vaultCredits[i] * totalSupplyBefore) / balanceBefore;
                if (mintedForAsset < minted) minted = mintedForAsset;
            }
            if (minted == 0) revert InvalidUnits();
        }

        idx.totalUnits = totalSupplyBefore + minted;
        IndexToken(idx.token).mintIndexUnits(to, minted);
        IndexToken(idx.token).recordMintDetails(to, minted, idx.assets, required, fees, 0);

        emit LibEqualIndex.Minted(indexId, to, minted, required);
    }

    /// @notice Burn index tokens and redeem bundle share + fee pot share, minus burn fee.
    function burn(uint256 indexId, uint256 units, address to)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256[] memory assetsOut)
    {
        LibCurrency.assertZeroMsgValue();
        if (units == 0 || units % LibEqualIndex.INDEX_SCALE != 0) revert InvalidUnits();
        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);
        uint256 totalSupply = idx.totalUnits;
        if (units > totalSupply) revert InvalidUnits();
        if (IndexToken(idx.token).balanceOf(msg.sender) < units) revert InvalidUnits();

        uint256 len = idx.assets.length;
        assetsOut = new uint256[](len);
        uint256[] memory feeAmounts = new uint256[](len);
        uint16 feeIndexShareBps = _mintBurnFeeIndexShareBps();

        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            uint256 vaultBalance = s().vaultBalances[indexId][asset];
            uint256 potBalance = s().feePots[indexId][asset];
            uint256 navShare = Math.mulDiv(vaultBalance, units, totalSupply);
            uint256 potShare = Math.mulDiv(potBalance, units, totalSupply);
            uint256 gross = navShare + potShare;
            uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
            uint256 payout = gross - burnFee;

            s().vaultBalances[indexId][asset] = vaultBalance - navShare;
            s().feePots[indexId][asset] = potBalance - potShare;
            _distributeIndexFee(indexId, idx, asset, burnFee, feeIndexShareBps);

            if (payout > 0) {
                if (LibCurrency.isNative(asset)) {
                    LibAppStorage.s().nativeTrackedTotal -= payout;
                }
                LibCurrency.transfer(asset, to, payout);
            }
            assetsOut[i] = payout;
            feeAmounts[i] = burnFee;
        }

        idx.totalUnits = totalSupply - units;
        IndexToken(idx.token).burnIndexUnits(msg.sender, units);
        IndexToken(idx.token).recordBurnDetails(msg.sender, units, idx.assets, assetsOut, feeAmounts, 0);

        emit LibEqualIndex.Burned(indexId, to, units, assetsOut);
    }

    /// @notice Flash borrow proportional bundle amounts for a given unit amount.
    function flashLoan(uint256 indexId, uint256 units, address receiver, bytes calldata data)
        external
        payable
        nonReentrant
        indexExists(indexId)
    {
        LibCurrency.assertZeroMsgValue();
        if (units == 0 || units % LibEqualIndex.INDEX_SCALE != 0) revert InvalidUnits();
        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);
        uint256 totalSupply = idx.totalUnits;
        if (totalSupply == 0 || units > totalSupply) revert InvalidUnits();

        uint256 len = idx.assets.length;
        address[] memory assets = idx.assets;
        uint256[] memory loanAmounts = new uint256[](len);
        uint256[] memory fees = new uint256[](len);
        uint256[] memory contractBalancesBefore = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            contractBalancesBefore[i] = LibCurrency.balanceOfSelf(asset);
            uint256 vaultBalance = s().vaultBalances[indexId][asset];
            uint256 navShare = Math.mulDiv(vaultBalance, units, totalSupply);
            loanAmounts[i] = navShare;
            uint256 fee = Math.mulDiv(navShare, idx.flashFeeBps, 10_000);
            fees[i] = fee;
            s().vaultBalances[indexId][asset] = vaultBalance - navShare;
            if (navShare > 0) {
                LibCurrency.transfer(asset, receiver, navShare);
            }
        }

        IEqualIndexFlashReceiver(receiver).onEqualIndexFlashLoan(indexId, units, assets, loanAmounts, fees, data);

        _finalizeFlashLoan(indexId, idx, assets, loanAmounts, fees, contractBalancesBefore);

        emit LibEqualIndex.FlashLoaned(indexId, receiver, units, loanAmounts, fees);
    }

    function _finalizeFlashLoan(
        uint256 indexId,
        Index storage idx,
        address[] memory assets,
        uint256[] memory loanAmounts,
        uint256[] memory fees,
        uint256[] memory contractBalancesBefore
    ) internal {
        uint16 poolFeeShareBps = _poolFeeShareBps();
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            _settleFlashLoanFee(
                indexId,
                idx,
                assets[i],
                loanAmounts[i],
                fees[i],
                contractBalancesBefore[i],
                poolFeeShareBps
            );
        }
    }

    function _settleFlashLoanFee(
        uint256 indexId,
        Index storage idx,
        address asset,
        uint256 loanAmount,
        uint256 fee,
        uint256 balanceBefore,
        uint16 poolFeeShareBps
    ) internal {
        uint256 expectedBalance = balanceBefore + fee;
        uint256 actualBalance = LibCurrency.balanceOfSelf(asset);
        if (actualBalance < expectedBalance) {
            revert FlashLoanUnderpaid(indexId, asset, expectedBalance, actualBalance);
        }
        s().vaultBalances[indexId][asset] += loanAmount;
        if (LibCurrency.isNative(asset) && fee > 0) {
            LibAppStorage.s().nativeTrackedTotal += fee;
        }
        _distributeIndexFee(indexId, idx, asset, fee, poolFeeShareBps);
    }

    function _pullNativeMint(uint256 amount) internal {
        if (amount == 0) {
            LibCurrency.assertZeroMsgValue();
            return;
        }
        if (msg.value == 0) {
            uint256 availableNative = LibCurrency.nativeAvailable();
            if (amount > availableNative) {
                revert InsufficientPoolLiquidity(amount, availableNative);
            }
            LibAppStorage.s().nativeTrackedTotal += amount;
            return;
        }
        if (msg.value != amount) {
            revert UnexpectedMsgValue(msg.value);
        }
        uint256 availableAfterValue = LibCurrency.nativeAvailable();
        uint256 preAvailable = availableAfterValue > msg.value ? availableAfterValue - msg.value : 0;
        LibAppStorage.s().nativeTrackedTotal += amount;
        if (preAvailable >= amount) {
            (bool success,) = msg.sender.call{value: msg.value}("");
            if (!success) {
                // Refunds are best-effort; keep funds if receiver rejects.
            }
        }
    }

    /// @dev Distributes index fee between Fee Pot and pool fee routing share.
    /// Uses feeIndexShareBps for the pool share, remainder goes to the Fee Pot.
    function _distributeIndexFee(
        uint256 indexId,
        Index storage idx,
        address asset,
        uint256 fee,
        uint16 feeIndexShareBps
    ) internal {
        if (fee == 0) return;

        // 1. Pool share routed through standard fee router (FI/ACI/Treasury).
        uint256 poolShare = Math.mulDiv(fee, feeIndexShareBps, 10_000);
        // 2. Fee pot share (index holders)
        uint256 potFee = fee - poolShare;
        if (potFee > 0) {
            s().feePots[indexId][asset] += potFee;
        }

        if (poolShare > 0) {
            uint256 poolId = LibAppStorage.s().assetToPoolId[asset];
            if (poolId == 0) revert NoPoolForAsset(asset);
            Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
            pool.trackedBalance += poolShare;
            // Count the incoming fee as backing even if tracked balance is slightly short.
            if (LibCurrency.isNative(asset)) {
                _routeIndexPoolShareNative(pool, poolId, poolShare);
            } else {
                LibFeeRouter.routeSamePool(poolId, poolShare, INDEX_FEE_SOURCE, true, poolShare);
            }
        }
    }

    function _routeIndexPoolShareNative(Types.PoolData storage pool, uint256 pid, uint256 amount) internal {
        if (amount == 0) return;
        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) = LibFeeRouter.previewSplit(amount);
        if (toTreasury > 0) {
            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury != address(0)) {
                uint256 tracked = pool.trackedBalance;
                if (tracked < toTreasury) {
                    revert InsufficientPrincipal(toTreasury, tracked);
                }
                uint256 contractBal = LibCurrency.balanceOfSelf(pool.underlying);
                if (contractBal < toTreasury) {
                    revert InsufficientPrincipal(toTreasury, contractBal);
                }
                pool.trackedBalance = tracked - toTreasury;
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
                LibCurrency.transfer(pool.underlying, treasury, toTreasury);
            }
        }
        if (toActiveCredit > 0) {
            LibFeeRouter.accrueActiveCredit(pid, toActiveCredit, INDEX_FEE_SOURCE, amount);
        }
        if (toFeeIndex > 0) {
            LibFeeIndex.accrueWithSourceUsingBacking(pid, toFeeIndex, INDEX_FEE_SOURCE, amount);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibFeeTreasury} from "./LibFeeTreasury.sol";
import {LibModuleEncumbrance} from "./LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "./LibModuleRegistry.sol";
import {Types} from "./Types.sol";
import {InsufficientPrincipal} from "./Errors.sol";

/// @notice Module AUM accrual logic over tuple module encumbrance.
library LibModuleAum {
    uint256 internal constant MODULE_AUM_EPOCH = 1 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR_DAYS = 365;
    bytes32 internal constant MODULE_AUM_SOURCE = keccak256("MODULE_AUM_FEE");

    struct AccrualResult {
        uint256 epochs;
        uint256 encumbered;
        uint16 aumBps;
        uint256 feeDue;
        uint256 charged;
        uint256 shortfall;
        bool delinquent;
        bool deactivated;
        uint64 lastAumEpoch;
    }

    function epochLength() internal pure returns (uint256) {
        return MODULE_AUM_EPOCH;
    }

    function currentEpochStart() internal view returns (uint64) {
        return uint64((block.timestamp / MODULE_AUM_EPOCH) * MODULE_AUM_EPOCH);
    }

    function effectiveAumBps(uint256 moduleId) internal view returns (uint16 bps) {
        bps = LibModuleRegistry.module(moduleId).aumBps;
        if (bps == 0) {
            bps = LibModuleRegistry.s().defaultModuleAumBps;
        }
    }

    function pendingEpochs(bytes32 positionKey, uint256 poolId, uint256 moduleId) internal view returns (uint256) {
        LibModuleRegistry.TupleAumState storage st = LibModuleRegistry.tupleAumState(positionKey, poolId, moduleId);
        if (st.lastAumEpoch == 0) {
            return 0;
        }
        uint64 epochStart = currentEpochStart();
        if (epochStart <= st.lastAumEpoch) {
            return 0;
        }
        return (uint256(epochStart) - uint256(st.lastAumEpoch)) / MODULE_AUM_EPOCH;
    }

    function delinquentEpochs(bytes32 positionKey, uint256 poolId, uint256 moduleId) internal view returns (uint256) {
        LibModuleRegistry.TupleAumState storage st = LibModuleRegistry.tupleAumState(positionKey, poolId, moduleId);
        if (!st.delinquent || st.delinquentSince == 0) {
            return 0;
        }
        uint64 epochStart = currentEpochStart();
        if (epochStart <= st.delinquentSince) {
            return 0;
        }
        return (uint256(epochStart) - uint256(st.delinquentSince)) / MODULE_AUM_EPOCH;
    }

    function accrue(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        internal
        returns (AccrualResult memory result)
    {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        LibModuleRegistry.TupleAumState storage st = ms.tupleAum[positionKey][poolId][moduleId];
        uint64 epochStart = currentEpochStart();

        if (st.lastAumEpoch == 0) {
            st.lastAumEpoch = epochStart;
            result.lastAumEpoch = epochStart;
            return result;
        }

        if (epochStart <= st.lastAumEpoch) {
            result.lastAumEpoch = st.lastAumEpoch;
            return result;
        }

        result.epochs = (uint256(epochStart) - uint256(st.lastAumEpoch)) / MODULE_AUM_EPOCH;
        if (result.epochs == 0) {
            result.lastAumEpoch = st.lastAumEpoch;
            return result;
        }

        result.encumbered = LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
        result.aumBps = effectiveAumBps(moduleId);
        result.feeDue = (result.encumbered * uint256(result.aumBps) * result.epochs) / (YEAR_DAYS * BPS_DENOMINATOR);

        // Always settle checkpoints before mutating principal, even when feeDue is 0.
        LibFeeIndex.settle(poolId, positionKey);

        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        uint256 chargeablePrincipal = pool.userPrincipal[positionKey];
        if (chargeablePrincipal > result.encumbered) {
            chargeablePrincipal = result.encumbered;
        }

        result.charged = result.feeDue <= chargeablePrincipal ? result.feeDue : chargeablePrincipal;
        if (result.charged > 0) {
            _chargeFromPrincipal(pool, poolId, positionKey, result.charged);
        }

        result.shortfall = result.feeDue - result.charged;
        st.lastAumEpoch = st.lastAumEpoch + uint64(result.epochs * MODULE_AUM_EPOCH);
        result.lastAumEpoch = st.lastAumEpoch;

        if (result.shortfall > 0) {
            _markDelinquency(
                ms, st, moduleId, positionKey, poolId, epochStart, result.feeDue, chargeablePrincipal, result.shortfall, result
            );
        } else {
            if (st.delinquent || st.delinquentSince != 0 || st.lastShortfall != 0) {
                st.delinquent = false;
                st.delinquentSince = 0;
                st.lastShortfall = 0;
            }
        }
        result.delinquent = st.delinquent;

        LibModuleRegistry.emitModuleAumAccrued(
            moduleId,
            positionKey,
            poolId,
            result.epochs,
            result.feeDue,
            result.charged,
            result.shortfall,
            result.lastAumEpoch
        );
    }

    function _chargeFromPrincipal(Types.PoolData storage pool, uint256 poolId, bytes32 positionKey, uint256 amount) private {
        pool.userPrincipal[positionKey] -= amount;
        pool.totalDeposits -= amount;

        (uint256 toTreasury,,) = LibFeeTreasury.accrueWithTreasuryFromPrincipal(pool, poolId, amount, MODULE_AUM_SOURCE);
        if (toTreasury == 0) {
            return;
        }

        if (pool.trackedBalance < toTreasury) {
            revert InsufficientPrincipal(toTreasury, pool.trackedBalance);
        }
        pool.trackedBalance -= toTreasury;

        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= toTreasury;
        }
    }

    function _markDelinquency(
        LibModuleRegistry.ModuleStorage storage ms,
        LibModuleRegistry.TupleAumState storage st,
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint64 epochStart,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall,
        AccrualResult memory result
    ) private {
        bool wasDelinquent = st.delinquent && st.delinquentSince != 0;
        if (!wasDelinquent) {
            st.delinquent = true;
            st.delinquentSince = epochStart;
        }
        st.lastShortfall = shortfall;

        LibModuleRegistry.emitModuleAumDelinquent(moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall);

        if (!wasDelinquent) {
            return;
        }

        LibModuleRegistry.Module storage moduleCfg = ms.modules[moduleId];
        if (moduleCfg.inactive) {
            return;
        }

        uint256 delinquentEpochCount = (uint256(epochStart) - uint256(st.delinquentSince)) / MODULE_AUM_EPOCH;
        if (delinquentEpochCount < ms.deactivationGraceEpochs) {
            return;
        }

        moduleCfg.inactive = true;
        result.deactivated = true;
        LibModuleRegistry.emitModulePermanentlyDeactivated(
            moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall
        );
    }
}

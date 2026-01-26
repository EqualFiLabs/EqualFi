// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibMamCurveHasher} from "../libraries/LibMamCurveHasher.sol";
import {MamTypes} from "../libraries/MamTypes.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/MamCurveErrors.sol";

/// @notice MAM curve lifecycle updates + cancellations.
contract MamCurveManagementFacet is ReentrancyGuardModifiers {
    event CurveUpdated(
        uint256 indexed curveId,
        bytes32 indexed makerPositionKey,
        uint32 generation,
        MamTypes.CurveUpdateParams params
    );

    event CurveCancelled(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint256 remainingVolume);
    event CurveExpired(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint256 remainingVolume);
    event CurvesBatchUpdated(bytes32 indexed makerPositionKey, uint256 count);
    event CurvesBatchCancelled(bytes32 indexed makerPositionKey, uint256 count);
    event CurvesBatchExpired(bytes32 indexed makerPositionKey, uint256 count);

    function updateCurve(uint256 curveId, MamTypes.CurveUpdateParams calldata params)
        external
        nonReentrant
    {
        _updateCurve(curveId, params);
    }

    function updateCurvesBatch(uint256[] calldata curveIds, MamTypes.CurveUpdateParams[] calldata params)
        external
        nonReentrant
    {
        uint256 length = curveIds.length;
        if (length == 0 || length != params.length) revert MamCurve_InvalidAmount(length);
        bytes32 positionKey;

        for (uint256 i = 0; i < length; i++) {
            bytes32 makerKey = _updateCurve(curveIds[i], params[i]);
            if (i == 0) {
                positionKey = makerKey;
            } else if (makerKey != positionKey) {
                revert MamCurve_InvalidDescriptor();
            }
        }

        emit CurvesBatchUpdated(positionKey, length);
    }

    function cancelCurve(uint256 curveId) external nonReentrant {
        _cancelCurve(curveId);
    }

    function cancelCurvesBatch(uint256[] calldata curveIds) external nonReentrant {
        uint256 length = curveIds.length;
        if (length == 0) revert MamCurve_InvalidAmount(length);
        bytes32 positionKey;

        for (uint256 i = 0; i < length; i++) {
            bytes32 makerKey = _cancelCurve(curveIds[i]);
            if (i == 0) {
                positionKey = makerKey;
            } else if (makerKey != positionKey) {
                revert MamCurve_InvalidDescriptor();
            }
        }

        emit CurvesBatchCancelled(positionKey, length);
    }

    function expireCurve(uint256 curveId) external nonReentrant {
        _expireCurve(curveId);
    }

    function expireCurvesBatch(uint256[] calldata curveIds) external nonReentrant {
        uint256 length = curveIds.length;
        if (length == 0) revert MamCurve_InvalidAmount(length);
        bytes32 positionKey;

        for (uint256 i = 0; i < length; i++) {
            bytes32 makerKey = _expireCurve(curveIds[i]);
            if (i == 0) {
                positionKey = makerKey;
            } else if (makerKey != positionKey) {
                revert MamCurve_InvalidDescriptor();
            }
        }

        emit CurvesBatchExpired(positionKey, length);
    }

    function _updateCurve(uint256 curveId, MamTypes.CurveUpdateParams calldata params)
        internal
        returns (bytes32 makerPositionKey)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) revert MamCurve_NotActive(curveId);

        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        makerPositionKey = data.makerPositionKey;

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(data.makerPositionId);
        if (positionKey != makerPositionKey) {
            revert MamCurve_NotMaker(msg.sender, data.makerPositionId);
        }

        if (params.startPrice == 0 || params.endPrice == 0) revert MamCurve_InvalidDescriptor();
        if (params.duration == 0) revert MamCurve_InvalidTime(params.startTime, params.duration);
        if (params.startTime < block.timestamp) revert MamCurve_InvalidTime(params.startTime, params.duration);

        uint256 endTime = uint256(params.startTime) + uint256(params.duration);
        if (endTime > type(uint64).max) revert MamCurve_InvalidTime(params.startTime, params.duration);

        uint32 newGen = curve.generation + 1;
        MamTypes.CurveDescriptor memory desc = _buildDescriptor(curveId, params, newGen);
        bytes32 newCommitment = LibMamCurveHasher.curveHash(desc);

        curve.commitment = newCommitment;
        curve.endTime = uint64(endTime);
        curve.generation = newGen;

        ds.curvePricing[curveId] = LibDerivativeStorage.CurvePricing({
            startPrice: params.startPrice,
            endPrice: params.endPrice,
            startTime: params.startTime,
            duration: params.duration
        });

        emit CurveUpdated(curveId, makerPositionKey, newGen, params);
    }

    function _cancelCurve(uint256 curveId) internal returns (bytes32 makerPositionKey) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) revert MamCurve_NotActive(curveId);

        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        makerPositionKey = data.makerPositionKey;

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(data.makerPositionId);
        if (positionKey != makerPositionKey) {
            revert MamCurve_NotMaker(msg.sender, data.makerPositionId);
        }

        uint128 remaining = curve.remainingVolume;
        if (remaining > 0) {
            bool baseIsA = ds.curveBaseIsA[curveId];
            uint256 basePoolId = baseIsA ? data.poolIdA : data.poolIdB;
            LibDerivativeHelpers._unlockCollateral(makerPositionKey, basePoolId, remaining);
        }

        curve.active = false;
        curve.remainingVolume = 0;
        curve.commitment = bytes32(0);

        LibDerivativeStorage.removeCurve(makerPositionKey, curveId);
        LibDerivativeStorage.removeCurveGlobal(curveId);
        LibDerivativeStorage.removeCurveByPair(imm.tokenA, imm.tokenB, curveId);

        emit CurveCancelled(curveId, makerPositionKey, remaining);
        return makerPositionKey;
    }

    function _expireCurve(uint256 curveId) internal returns (bytes32 makerPositionKey) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) revert MamCurve_NotActive(curveId);
        if (block.timestamp <= curve.endTime) revert MamCurve_NotExpired(curveId);

        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        makerPositionKey = data.makerPositionKey;

        uint128 remaining = curve.remainingVolume;
        if (remaining > 0) {
            bool baseIsA = ds.curveBaseIsA[curveId];
            uint256 basePoolId = baseIsA ? data.poolIdA : data.poolIdB;
            LibDerivativeHelpers._unlockCollateral(makerPositionKey, basePoolId, remaining);
        }

        curve.active = false;
        curve.remainingVolume = 0;
        curve.commitment = bytes32(0);

        LibDerivativeStorage.removeCurve(makerPositionKey, curveId);
        LibDerivativeStorage.removeCurveGlobal(curveId);
        LibDerivativeStorage.removeCurveByPair(imm.tokenA, imm.tokenB, curveId);

        emit CurveExpired(curveId, makerPositionKey, remaining);
    }

    function _buildDescriptor(
        uint256 curveId,
        MamTypes.CurveUpdateParams calldata params,
        uint32 newGen
    ) internal view returns (MamTypes.CurveDescriptor memory desc) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];

        desc.makerPositionKey = data.makerPositionKey;
        desc.makerPositionId = data.makerPositionId;
        desc.poolIdA = data.poolIdA;
        desc.poolIdB = data.poolIdB;
        desc.tokenA = imm.tokenA;
        desc.tokenB = imm.tokenB;
        desc.side = !ds.curveBaseIsA[curveId];
        desc.priceIsQuotePerBase = imm.priceIsQuotePerBase;
        desc.maxVolume = imm.maxVolume;
        desc.startPrice = params.startPrice;
        desc.endPrice = params.endPrice;
        desc.startTime = params.startTime;
        desc.duration = params.duration;
        desc.generation = newGen;
        desc.feeRateBps = imm.feeRateBps;
        desc.feeAsset = imm.feeAsset;
        desc.salt = imm.salt;
    }
}

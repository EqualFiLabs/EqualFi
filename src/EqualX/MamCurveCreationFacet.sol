// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibMamCurveHasher} from "../libraries/LibMamCurveHasher.sol";
import {MamTypes} from "../libraries/MamTypes.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {PoolMembershipRequired} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/MamCurveErrors.sol";

/// @notice MAM curve creation + config facet.
contract MamCurveCreationFacet is ReentrancyGuardModifiers {
    uint256 internal constant MAX_PAST_START = 30 minutes;

    event CurveCreated(
        uint256 indexed curveId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        address tokenA,
        address tokenB,
        bool baseIsA,
        uint128 maxVolume,
        uint128 startPrice,
        uint128 endPrice,
        uint64 startTime,
        uint64 duration,
        uint16 feeRateBps
    );

    event CurvesBatchCreated(bytes32 indexed makerPositionKey, uint256 indexed firstCurveId, uint256 count);
    event MamPausedUpdated(bool paused);

    function setMamPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDerivativeStorage.derivativeStorage().mamPaused = paused;
        emit MamPausedUpdated(paused);
    }

    function createCurve(MamTypes.CurveDescriptor calldata desc)
        external
        nonReentrant
        returns (uint256 curveId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        if (ds.mamPaused) revert MamCurve_Paused();

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(desc.makerPositionId);
        if (desc.makerPositionKey != positionKey) revert MamCurve_InvalidDescriptor();

        (bool baseIsA, uint256 endTime) = _validateDescriptor(desc, positionKey);

        uint256 basePoolId = baseIsA ? desc.poolIdA : desc.poolIdB;
        LibDerivativeHelpers._lockCollateral(positionKey, basePoolId, desc.maxVolume);

        curveId = ++ds.nextCurveId;
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        curve.commitment = LibMamCurveHasher.curveHash(desc);
        curve.remainingVolume = desc.maxVolume;
        curve.endTime = uint64(endTime);
        curve.generation = desc.generation;
        curve.active = true;

        ds.curveData[curveId] = LibDerivativeStorage.CurveData({
            makerPositionKey: positionKey,
            makerPositionId: desc.makerPositionId,
            poolIdA: desc.poolIdA,
            poolIdB: desc.poolIdB
        });
        ds.curveImmutables[curveId] = LibDerivativeStorage.CurveImmutables({
            tokenA: desc.tokenA,
            tokenB: desc.tokenB,
            maxVolume: desc.maxVolume,
            salt: desc.salt,
            feeRateBps: desc.feeRateBps,
            priceIsQuotePerBase: desc.priceIsQuotePerBase,
            feeAsset: desc.feeAsset
        });
        ds.curvePricing[curveId] = LibDerivativeStorage.CurvePricing({
            startPrice: desc.startPrice,
            endPrice: desc.endPrice,
            startTime: desc.startTime,
            duration: desc.duration
        });
        ds.curveImmutableHash[curveId] = _immutableHash(desc);
        ds.curveBaseIsA[curveId] = baseIsA;

        LibDerivativeStorage.addCurve(positionKey, curveId);
        LibDerivativeStorage.addCurveGlobal(curveId);
        LibDerivativeStorage.addCurveByPair(desc.tokenA, desc.tokenB, curveId);

        emit CurveCreated(
            curveId,
            positionKey,
            desc.makerPositionId,
            desc.poolIdA,
            desc.poolIdB,
            desc.tokenA,
            desc.tokenB,
            baseIsA,
            desc.maxVolume,
            desc.startPrice,
            desc.endPrice,
            desc.startTime,
            desc.duration,
            desc.feeRateBps
        );
    }

    function createCurvesBatch(MamTypes.CurveDescriptor[] calldata descs)
        external
        nonReentrant
        returns (uint256 firstCurveId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        if (ds.mamPaused) revert MamCurve_Paused();
        uint256 length = descs.length;
        if (length == 0) revert MamCurve_InvalidAmount(length);

        bytes32 positionKey;
        uint256 makerPositionId;
        firstCurveId = ds.nextCurveId + 1;

        for (uint256 i = 0; i < length; i++) {
            MamTypes.CurveDescriptor calldata desc = descs[i];
            bytes32 currentKey = LibDerivativeHelpers._requirePositionOwnership(desc.makerPositionId);
            if (desc.makerPositionKey != currentKey) revert MamCurve_InvalidDescriptor();
            if (i == 0) {
                positionKey = currentKey;
                makerPositionId = desc.makerPositionId;
            } else if (currentKey != positionKey || desc.makerPositionId != makerPositionId) {
                revert MamCurve_InvalidDescriptor();
            }
            _createCurveInternal(ds, desc, positionKey);
        }

        emit CurvesBatchCreated(positionKey, firstCurveId, length);
    }

    function _createCurveInternal(
        LibDerivativeStorage.DerivativeStorage storage ds,
        MamTypes.CurveDescriptor calldata desc,
        bytes32 positionKey
    ) internal {
        (bool baseIsA, uint256 endTime) = _validateDescriptor(desc, positionKey);
        uint256 basePoolId = baseIsA ? desc.poolIdA : desc.poolIdB;
        LibDerivativeHelpers._lockCollateral(positionKey, basePoolId, desc.maxVolume);

        uint256 curveId = ++ds.nextCurveId;
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        curve.commitment = LibMamCurveHasher.curveHash(desc);
        curve.remainingVolume = desc.maxVolume;
        curve.endTime = uint64(endTime);
        curve.generation = desc.generation;
        curve.active = true;

        ds.curveData[curveId] = LibDerivativeStorage.CurveData({
            makerPositionKey: positionKey,
            makerPositionId: desc.makerPositionId,
            poolIdA: desc.poolIdA,
            poolIdB: desc.poolIdB
        });
        ds.curveImmutables[curveId] = LibDerivativeStorage.CurveImmutables({
            tokenA: desc.tokenA,
            tokenB: desc.tokenB,
            maxVolume: desc.maxVolume,
            salt: desc.salt,
            feeRateBps: desc.feeRateBps,
            priceIsQuotePerBase: desc.priceIsQuotePerBase,
            feeAsset: desc.feeAsset
        });
        ds.curvePricing[curveId] = LibDerivativeStorage.CurvePricing({
            startPrice: desc.startPrice,
            endPrice: desc.endPrice,
            startTime: desc.startTime,
            duration: desc.duration
        });
        ds.curveImmutableHash[curveId] = _immutableHash(desc);
        ds.curveBaseIsA[curveId] = baseIsA;

        LibDerivativeStorage.addCurve(positionKey, curveId);
        LibDerivativeStorage.addCurveGlobal(curveId);
        LibDerivativeStorage.addCurveByPair(desc.tokenA, desc.tokenB, curveId);

        emit CurveCreated(
            curveId,
            positionKey,
            desc.makerPositionId,
            desc.poolIdA,
            desc.poolIdB,
            desc.tokenA,
            desc.tokenB,
            baseIsA,
            desc.maxVolume,
            desc.startPrice,
            desc.endPrice,
            desc.startTime,
            desc.duration,
            desc.feeRateBps
        );
    }

    function _validateDescriptor(MamTypes.CurveDescriptor calldata desc, bytes32 positionKey)
        internal
        returns (bool baseIsA, uint256 endTime)
    {
        if (desc.maxVolume == 0) revert MamCurve_InvalidAmount(desc.maxVolume);
        if (desc.startPrice == 0 || desc.endPrice == 0) revert MamCurve_InvalidDescriptor();
        if (desc.duration == 0) revert MamCurve_InvalidTime(desc.startTime, desc.duration);
        if (block.timestamp > uint256(desc.startTime) + MAX_PAST_START) {
            revert MamCurve_InvalidTime(desc.startTime, desc.duration);
        }
        if (!desc.priceIsQuotePerBase) revert MamCurve_InvalidDescriptor();
        if (desc.feeAsset != MamTypes.FeeAsset.TokenIn) revert MamCurve_InvalidDescriptor();
        if (desc.generation != 1) revert MamCurve_InvalidDescriptor();
        if (desc.poolIdA == desc.poolIdB) revert MamCurve_InvalidPool(desc.poolIdA);
        if (desc.tokenA == address(0) || desc.tokenB == address(0)) revert MamCurve_InvalidDescriptor();
        if (desc.tokenA == desc.tokenB) revert MamCurve_InvalidDescriptor();

        Types.PoolData storage poolA = LibDirectHelpers._pool(desc.poolIdA);
        Types.PoolData storage poolB = LibDirectHelpers._pool(desc.poolIdB);
        if (poolA.underlying != desc.tokenA) revert MamCurve_InvalidDescriptor();
        if (poolB.underlying != desc.tokenB) revert MamCurve_InvalidDescriptor();

        if (!LibPoolMembership.isMember(positionKey, desc.poolIdA)) {
            revert PoolMembershipRequired(positionKey, desc.poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, desc.poolIdB)) {
            revert PoolMembershipRequired(positionKey, desc.poolIdB);
        }

        LibFeeIndex.settle(desc.poolIdA, positionKey);
        LibActiveCreditIndex.settle(desc.poolIdA, positionKey);
        LibFeeIndex.settle(desc.poolIdB, positionKey);
        LibActiveCreditIndex.settle(desc.poolIdB, positionKey);

        endTime = uint256(desc.startTime) + uint256(desc.duration);
        if (endTime > type(uint64).max) revert MamCurve_InvalidTime(desc.startTime, desc.duration);
        baseIsA = !desc.side;
    }

    function _immutableHash(MamTypes.CurveDescriptor calldata desc) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                desc.makerPositionKey,
                desc.makerPositionId,
                desc.poolIdA,
                desc.poolIdB,
                desc.tokenA,
                desc.tokenB,
                desc.side,
                desc.priceIsQuotePerBase,
                desc.maxVolume,
                desc.feeRateBps,
                desc.feeAsset,
                desc.salt
            )
        );
    }
}

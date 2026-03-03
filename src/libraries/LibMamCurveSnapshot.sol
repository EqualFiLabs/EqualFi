// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDerivativeStorage} from "./LibDerivativeStorage.sol";
import {MamTypes} from "./MamTypes.sol";

/// @notice Event-only packed snapshots for MAM curve indexing.
library LibMamCurveSnapshot {
    uint8 internal constant PACKING_VERSION_V1 = 1;

    uint8 internal constant STATUS_CREATED = 1;
    uint8 internal constant STATUS_UPDATED = 2;
    uint8 internal constant STATUS_FILLED = 3;
    uint8 internal constant STATUS_CANCELLED = 4;
    uint8 internal constant STATUS_EXPIRED = 5;

    event CurveSnapshotPackedV1(
        uint256 indexed curveId,
        bytes32 indexed makerPositionKey,
        bytes32 indexed pairKey,
        uint256 metaWord,
        uint256 priceWord,
        uint256 volumeWord,
        address profile,
        bytes32 profileParams,
        bytes32 commitment
    );

    function emitSnapshotPackedV1(
        uint256 curveId,
        bytes32 makerPositionKey,
        address tokenA,
        address tokenB,
        uint16 feeRateBps,
        uint32 generation,
        uint64 startTime,
        uint64 duration,
        bool baseIsA,
        bool priceIsQuotePerBase,
        uint8 status,
        uint128 startPrice,
        uint128 endPrice,
        uint128 maxVolume,
        uint128 remainingVolume,
        address profile,
        bytes32 profileParams,
        bytes32 commitment
    ) internal {
        bytes32 pairKey = pairKeyForTokens(tokenA, tokenB);
        uint256 metaWord = packMetaWord(
            feeRateBps,
            generation,
            startTime,
            duration,
            baseIsA,
            priceIsQuotePerBase,
            status,
            PACKING_VERSION_V1
        );
        uint256 priceWord = packPriceWord(startPrice, endPrice);
        uint256 volumeWord = packVolumeWord(maxVolume, remainingVolume);

        emit CurveSnapshotPackedV1(
            curveId,
            makerPositionKey,
            pairKey,
            metaWord,
            priceWord,
            volumeWord,
            profile,
            profileParams,
            commitment
        );
    }

    function emitSnapshotForCurve(uint256 curveId, uint8 status) internal {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[curveId];
        LibDerivativeStorage.CurveProfileData storage prof = ds.curveProfileData[curveId];
        bytes32 pairKey = pairKeyForTokens(imm.tokenA, imm.tokenB);
        uint256 metaWord = packMetaWord(
            imm.feeRateBps,
            curve.generation,
            pricing.startTime,
            pricing.duration,
            ds.curveBaseIsA[curveId],
            imm.priceIsQuotePerBase,
            status,
            PACKING_VERSION_V1
        );
        uint256 priceWord = packPriceWord(pricing.startPrice, pricing.endPrice);
        uint256 volumeWord = packVolumeWord(imm.maxVolume, curve.remainingVolume);

        emit CurveSnapshotPackedV1(
            curveId,
            data.makerPositionKey,
            pairKey,
            metaWord,
            priceWord,
            volumeWord,
            prof.profile,
            prof.profileParams,
            curve.commitment
        );
    }

    function pairKeyForTokens(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(token0, token1));
    }

    function packMetaWord(
        uint16 feeRateBps,
        uint32 generation,
        uint64 startTime,
        uint64 duration,
        bool baseIsA,
        bool priceIsQuotePerBase,
        uint8 status,
        uint8 version
    ) internal pure returns (uint256 metaWord) {
        metaWord = uint256(feeRateBps);
        metaWord |= uint256(generation) << 16;
        metaWord |= uint256(startTime) << 48;
        metaWord |= uint256(duration) << 112;
        if (baseIsA) metaWord |= uint256(1) << 176;
        if (priceIsQuotePerBase) metaWord |= uint256(1) << 177;
        metaWord |= uint256(status) << 178;
        metaWord |= uint256(version) << 186;
    }

    function packPriceWord(uint128 startPrice, uint128 endPrice) internal pure returns (uint256 priceWord) {
        priceWord = uint256(startPrice);
        priceWord |= uint256(endPrice) << 128;
    }

    function packVolumeWord(uint128 maxVolume, uint128 remainingVolume)
        internal
        pure
        returns (uint256 volumeWord)
    {
        volumeWord = uint256(maxVolume);
        volumeWord |= uint256(remainingVolume) << 128;
    }
}

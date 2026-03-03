// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {MamTypes} from "../libraries/MamTypes.sol";
import {LibMamMath} from "../libraries/LibMamMath.sol";
import {LibMamProfile} from "../libraries/LibMamProfile.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @notice View-only facet for MAM curve state.
contract MamCurveViewFacet {
    function getCurve(uint256 curveId)
        external
        view
        returns (
            MamTypes.StoredCurve memory curve,
            LibDerivativeStorage.CurveData memory data,
            LibDerivativeStorage.CurvePricing memory pricing,
            LibDerivativeStorage.CurveProfileData memory profileData,
            LibDerivativeStorage.CurveImmutables memory immutables,
            bool baseIsA
        )
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        curve = ds.curves[curveId];
        data = ds.curveData[curveId];
        pricing = ds.curvePricing[curveId];
        profileData = ds.curveProfileData[curveId];
        immutables = ds.curveImmutables[curveId];
        baseIsA = ds.curveBaseIsA[curveId];
    }

    function getCurvesByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.curvesPage(positionKey, offset, limit);
    }

    function getCurvesByPositionId(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.curvesPage(_positionKey(positionId), offset, limit);
    }

    function getActiveCurves(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.curvesGlobalPage(offset, limit);
    }

    function getCurvesByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.curvesByPairPage(tokenA, tokenB, offset, limit);
    }

    function getCurveStatus(uint256 curveId)
        external
        view
        returns (
            bool active,
            bool expired,
            uint128 remainingVolume,
            uint256 currentPrice,
            uint64 startTime,
            uint64 endTime,
            bool baseIsA,
            address tokenA,
            address tokenB,
            uint256 timeRemaining
        )
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[curveId];
        LibDerivativeStorage.CurveProfileData storage profileData = ds.curveProfileData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];

        active = curve.active;
        remainingVolume = curve.remainingVolume;
        startTime = pricing.startTime;
        endTime = curve.endTime;
        expired = block.timestamp > endTime;
        baseIsA = ds.curveBaseIsA[curveId];
        tokenA = imm.tokenA;
        tokenB = imm.tokenB;
        currentPrice = _computeViewPrice(ds, pricing, profileData.profileId, profileData.profileParams);
        if (block.timestamp < endTime) {
            timeRemaining = endTime - block.timestamp;
        }
    }

    function quoteCurveExactIn(uint256 curveId, uint256 amountIn)
        external
        view
        returns (
            uint256 amountOut,
            uint256 feeAmount,
            uint256 totalQuote,
            uint128 remainingVolume,
            bool ok
        )
    {
        return _quoteCurveExactIn(curveId, amountIn, false);
    }

    function quoteCurvesExactInBatch(uint256[] calldata curveIds, uint256[] calldata amountIns)
        external
        view
        returns (uint256[] memory amountOuts, uint256[] memory feeAmounts, bool[] memory oks)
    {
        uint256 len = curveIds.length;
        require(len == amountIns.length, "MamCurveView: length mismatch");
        amountOuts = new uint256[](len);
        feeAmounts = new uint256[](len);
        oks = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            (uint256 out, uint256 fee,, uint128 remaining, bool ok) =
                _quoteCurveExactIn(curveIds[i], amountIns[i], true);
            remaining;
            amountOuts[i] = out;
            feeAmounts[i] = fee;
            oks[i] = ok;
        }
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](8);
        selectorsArr[0] = MamCurveViewFacet.getCurve.selector;
        selectorsArr[1] = MamCurveViewFacet.getCurvesByPosition.selector;
        selectorsArr[2] = MamCurveViewFacet.getCurvesByPositionId.selector;
        selectorsArr[3] = MamCurveViewFacet.getActiveCurves.selector;
        selectorsArr[4] = MamCurveViewFacet.getCurvesByPair.selector;
        selectorsArr[5] = MamCurveViewFacet.getCurveStatus.selector;
        selectorsArr[6] = MamCurveViewFacet.quoteCurveExactIn.selector;
        selectorsArr[7] = MamCurveViewFacet.quoteCurvesExactInBatch.selector;
    }

    function _positionKey(uint256 positionId) private view returns (bytes32) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        require(ns.nftModeEnabled && ns.positionNFTContract != address(0), "MamCurveView: position NFT disabled");
        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        return nft.getPositionKey(positionId);
    }

    function _quoteCurveExactIn(uint256 curveId, uint256 amountIn, bool suppressProfileRevert)
        private
        view
        returns (
            uint256 amountOut,
            uint256 feeAmount,
            uint256 totalQuote,
            uint128 remainingVolume,
            bool ok
        )
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) {
            return (0, 0, 0, curve.remainingVolume, false);
        }

        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[curveId];
        LibDerivativeStorage.CurveProfileData storage profileData = ds.curveProfileData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];

        uint256 endTime = uint256(pricing.startTime) + uint256(pricing.duration);
        if (block.timestamp < pricing.startTime || block.timestamp > endTime) {
            return (0, 0, 0, curve.remainingVolume, false);
        }

        uint256 price;
        if (suppressProfileRevert) {
            (bool priceOk, uint256 computedPrice) =
                _tryComputeViewPrice(ds, pricing, profileData.profileId, profileData.profileParams);
            if (!priceOk) {
                return (0, 0, 0, curve.remainingVolume, false);
            }
            price = computedPrice;
        } else {
            price = _computeViewPrice(ds, pricing, profileData.profileId, profileData.profileParams);
        }
        uint256 baseFill = LibMamMath.amountOutForFill(amountIn, price);
        if (baseFill == 0 || baseFill > curve.remainingVolume) {
            return (0, 0, 0, curve.remainingVolume, false);
        }
        feeAmount = imm.feeRateBps == 0 ? 0 : LibMamMath.computeFeeBps(amountIn, imm.feeRateBps);
        totalQuote = amountIn + feeAmount;
        remainingVolume = curve.remainingVolume;
        amountOut = baseFill;
        ok = true;
    }

    function _computeViewPrice(
        LibDerivativeStorage.DerivativeStorage storage ds,
        LibDerivativeStorage.CurvePricing storage pricing,
        uint16 profileId,
        bytes32 profileParams
    )
        private
        view
        returns (uint256 price)
    {
        price = LibMamProfile.computePrice(ds, pricing, profileId, profileParams);
    }

    function _tryComputeViewPrice(
        LibDerivativeStorage.DerivativeStorage storage ds,
        LibDerivativeStorage.CurvePricing storage pricing,
        uint16 profileId,
        bytes32 profileParams
    )
        private
        view
        returns (bool success, uint256 price)
    {
        (success, price) = LibMamProfile.tryComputePrice(ds, pricing, profileId, profileParams);
    }
}

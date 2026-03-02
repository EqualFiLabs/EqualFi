// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibMamMath} from "../libraries/LibMamMath.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibPoints} from "../libraries/LibPoints.sol";
import {ICurveProfile} from "../interfaces/ICurveProfile.sol";
import {MamTypes} from "../libraries/MamTypes.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/MamCurveErrors.sol";

/// @notice MAM curve swap execution facet.
contract MamCurveExecutionFacet is ReentrancyGuardModifiers {
    bytes32 internal constant MAM_FEE_SOURCE = keccak256("MAM_CURVE_FILL");

    event CurveFilled(
        uint256 indexed curveId,
        address indexed taker,
        address indexed recipient,
        uint256 amountIn,
        uint256 actualIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 remainingVolume
    );

    function loadCurveForFill(uint256 curveId)
        external
        view
        returns (MamTypes.CurveFillView memory viewData)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) revert MamCurve_NotActive(curveId);

        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[curveId];
        LibDerivativeStorage.CurveProfileData storage prof = ds.curveProfileData[curveId];

        viewData = MamTypes.CurveFillView({
            makerPositionKey: data.makerPositionKey,
            makerPositionId: data.makerPositionId,
            poolIdA: data.poolIdA,
            poolIdB: data.poolIdB,
            tokenA: imm.tokenA,
            tokenB: imm.tokenB,
            baseIsA: ds.curveBaseIsA[curveId],
            startPrice: pricing.startPrice,
            endPrice: pricing.endPrice,
            startTime: pricing.startTime,
            duration: pricing.duration,
            feeRateBps: imm.feeRateBps,
            remainingVolume: curve.remainingVolume,
            profile: prof.profile,
            profileParams: prof.profileParams
        });
    }

    /// @notice Preview the total quote required for a curve swap (amountIn + fee).
    function previewCurveQuote(uint256 curveId, uint256 amountIn) external view returns (uint256 maxQuote) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        uint256 feeAmount = imm.feeRateBps == 0 ? 0 : LibMamMath.computeFeeBps(amountIn, imm.feeRateBps);
        maxQuote = amountIn + feeAmount;
    }

    function executeCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        amountOut = _executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            minOut,
            deadline,
            recipient,
            curve.generation,
            curve.commitment
        );
    }

    function executeCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient,
        uint32 expectedGeneration,
        bytes32 expectedCommitment
    ) external payable nonReentrant returns (uint256 amountOut) {
        amountOut = _executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            minOut,
            deadline,
            recipient,
            expectedGeneration,
            expectedCommitment
        );
    }

    function _executeCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient,
        uint32 expectedGeneration,
        bytes32 expectedCommitment
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert MamCurve_InvalidAmount(amountIn);
        if (recipient == address(0)) revert MamCurve_InvalidDescriptor();
        if (block.timestamp > deadline) revert MamCurve_Expired(curveId);

        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active) revert MamCurve_NotActive(curveId);
        if (curve.generation != expectedGeneration) revert MamCurve_GenerationMismatch(expectedGeneration, curve.generation);
        if (curve.commitment != expectedCommitment) {
            revert MamCurve_CommitmentMismatch(expectedCommitment, curve.commitment);
        }

        LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[curveId];
        LibDerivativeStorage.CurveProfileData storage prof = ds.curveProfileData[curveId];

        uint256 endTime = uint256(pricing.startTime) + uint256(pricing.duration);
        if (block.timestamp < pricing.startTime || block.timestamp > endTime) {
            revert MamCurve_Expired(curveId);
        }

        uint256 price = _computePrice(pricing, prof.profile, prof.profileParams);
        uint256 baseFill = LibMamMath.amountOutForFill(amountIn, price);
        if (baseFill == 0) revert MamCurve_InvalidAmount(baseFill);
        if (baseFill > curve.remainingVolume) {
            revert MamCurve_InsufficientVolume(baseFill, curve.remainingVolume);
        }
        amountOut = baseFill;
        if (amountOut < minOut) revert MamCurve_Slippage(minOut, amountOut);

        uint256 feeAmount = imm.feeRateBps == 0
            ? 0
            : LibMamMath.computeFeeBps(amountIn, imm.feeRateBps);
        uint256 totalQuote = amountIn + feeAmount;

        bool baseIsA = ds.curveBaseIsA[curveId];
        uint256 basePoolId = baseIsA ? data.poolIdA : data.poolIdB;
        uint256 quotePoolId = baseIsA ? data.poolIdB : data.poolIdA;
        address baseToken = baseIsA ? imm.tokenA : imm.tokenB;
        address quoteToken = baseIsA ? imm.tokenB : imm.tokenA;

        LibCurrency.assertMsgValue(quoteToken, maxQuote);
        uint256 received = LibCurrency.pullAtLeast(quoteToken, msg.sender, totalQuote, maxQuote);
        uint256 excess = received - totalQuote;

        Types.PoolData storage quotePool = LibAppStorage.s().pools[quotePoolId];
        quotePool.trackedBalance += totalQuote;

        uint16 makerShareBps = ds.config.mamMakerShareBps;
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;

        uint256 makerIncrease = amountIn + makerFee;
        quotePool.userPrincipal[data.makerPositionKey] += makerIncrease;
        quotePool.totalDeposits += makerIncrease;

        if (protocolFee > 0) {
            LibFeeRouter.routeSamePool(quotePoolId, protocolFee, MAM_FEE_SOURCE, true, 0);
        }

        Types.PoolData storage basePool = LibAppStorage.s().pools[basePoolId];
        LibDerivativeHelpers._unlockCollateral(data.makerPositionKey, basePoolId, baseFill);

        uint256 makerBase = basePool.userPrincipal[data.makerPositionKey];
        if (makerBase < baseFill) revert InsufficientPrincipal(baseFill, makerBase);
        if (basePool.trackedBalance < baseFill) {
            revert InsufficientPrincipal(baseFill, basePool.trackedBalance);
        }

        basePool.userPrincipal[data.makerPositionKey] = makerBase - baseFill;
        basePool.totalDeposits = basePool.totalDeposits >= baseFill
            ? basePool.totalDeposits - baseFill
            : 0;
        basePool.trackedBalance -= baseFill;

        uint256 remaining = _consumeCurve(curveId, uint128(baseFill));

        if (excess > 0) {
            if (LibCurrency.isNative(quoteToken)) {
                LibAppStorage.s().nativeTrackedTotal -= excess;
            }
            LibCurrency.transfer(quoteToken, msg.sender, excess);
        }

        if (LibCurrency.isNative(baseToken)) {
            LibAppStorage.s().nativeTrackedTotal -= baseFill;
        }
        LibCurrency.transferWithMin(baseToken, recipient, baseFill, minOut);
        LibPoints.accrueToDefaultPosition(msg.sender, LibPoints.ACTION_SWAP_MAM_CURVE);

        emit CurveFilled(curveId, msg.sender, recipient, amountIn, totalQuote, amountOut, feeAmount, remaining);
    }

    function _computePrice(LibDerivativeStorage.CurvePricing storage pricing, address profile, bytes32 profileParams)
        internal
        view
        returns (uint256 price)
    {
        if (profile == address(0)) {
            return LibMamMath.computePrice(
                pricing.startPrice,
                pricing.endPrice,
                pricing.startTime,
                pricing.duration,
                block.timestamp
            );
        }

        (bool success, bytes memory ret) = profile.staticcall(
            abi.encodeCall(
                ICurveProfile.computePrice,
                (
                    pricing.startPrice,
                    pricing.endPrice,
                    pricing.startTime,
                    pricing.duration,
                    block.timestamp,
                    profileParams
                )
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        price = abi.decode(ret, (uint256));
    }

    function _consumeCurve(uint256 curveId, uint128 baseFill) internal returns (uint128 remainingAfter) {
        if (baseFill == 0) revert MamCurve_InvalidAmount(baseFill);
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        if (!curve.active || block.timestamp > curve.endTime) {
            revert MamCurve_NotActive(curveId);
        }
        uint128 remaining = curve.remainingVolume;
        if (remaining < baseFill) revert MamCurve_InsufficientVolume(baseFill, remaining);
        unchecked {
            remaining = remaining - baseFill;
        }
        curve.remainingVolume = remaining;
        if (remaining == 0) {
            curve.active = false;
            LibDerivativeStorage.CurveData storage data = ds.curveData[curveId];
            LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[curveId];
            LibDerivativeStorage.removeCurve(data.makerPositionKey, curveId);
            LibDerivativeStorage.removeCurveGlobal(curveId);
            LibDerivativeStorage.removeCurveByPair(imm.tokenA, imm.tokenB, curveId);
        }
        return remaining;
    }
}

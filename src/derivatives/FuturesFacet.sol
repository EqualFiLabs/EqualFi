// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {FuturesToken} from "../derivatives/FuturesToken.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibDerivativeFees} from "../libraries/LibDerivativeFees.sol";
import {LibFeeTreasury} from "../libraries/LibFeeTreasury.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal, PoolMembershipRequired} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";

error Futures_Paused();
error Futures_InvalidAmount(uint256 amount);
error Futures_InvalidPrice(uint256 forwardPrice);
error Futures_InvalidExpiry(uint64 expiry);
error Futures_InvalidPool(uint256 poolId);
error Futures_InvalidAssetPair(address underlying, address quote);
error Futures_InvalidSeries(uint256 seriesId);
error Futures_SettlementWindowClosed(uint256 seriesId);
error Futures_GracePeriodNotElapsed(uint256 seriesId);
error Futures_Reclaimed(uint256 seriesId);
error Futures_NotTokenHolder(address caller, uint256 seriesId);
error Futures_InvalidRecipient(address recipient);
error Futures_InsufficientBalance(address holder, uint256 required, uint256 available);
error Futures_TokenNotSet();

/// @notice Futures facet for physical delivery futures series.
contract FuturesFacet is ReentrancyGuardModifiers {
    event SeriesCreated(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 underlyingPoolId,
        uint256 quotePoolId,
        address underlyingAsset,
        address quoteAsset,
        uint256 forwardPrice,
        uint64 expiry,
        uint256 totalSize,
        uint256 underlyingLocked,
        uint64 graceUnlockTime,
        bool isEuropean
    );

    event Settled(
        uint256 indexed seriesId,
        address indexed holder,
        address indexed recipient,
        uint256 amount,
        uint256 quoteAmount
    );

    event Reclaimed(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 remainingSize,
        uint256 collateralUnlocked
    );

    event FuturesTokenUpdated(address indexed token);
    event FuturesPausedUpdated(bool paused);

    function setFuturesToken(address token) external {
        LibAccess.enforceOwnerOrTimelock();
        if (token == address(0)) revert Futures_TokenNotSet();
        LibDerivativeStorage.derivativeStorage().futuresToken = token;
        emit FuturesTokenUpdated(token);
    }

    function setFuturesPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDerivativeStorage.derivativeStorage().futuresPaused = paused;
        emit FuturesPausedUpdated(paused);
    }

    function createFuturesSeries(DerivativeTypes.CreateFuturesSeriesParams calldata params)
        external
        nonReentrant
        returns (uint256 seriesId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.DerivativeConfig storage cfg = ds.config;
        if (ds.futuresPaused) revert Futures_Paused();
        if (params.totalSize == 0) revert Futures_InvalidAmount(params.totalSize);
        if (params.forwardPrice == 0) revert Futures_InvalidPrice(params.forwardPrice);
        if (params.expiry <= block.timestamp) revert Futures_InvalidExpiry(params.expiry);
        if (params.underlyingPoolId == params.quotePoolId) {
            revert Futures_InvalidPool(params.underlyingPoolId);
        }

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(params.positionId);

        Types.PoolData storage underlyingPool = LibDirectHelpers._pool(params.underlyingPoolId);
        Types.PoolData storage quotePool = LibDirectHelpers._pool(params.quotePoolId);
        if (underlyingPool.underlying == quotePool.underlying) {
            revert Futures_InvalidAssetPair(underlyingPool.underlying, quotePool.underlying);
        }
        if (!LibPoolMembership.isMember(positionKey, params.underlyingPoolId)) {
            revert PoolMembershipRequired(positionKey, params.underlyingPoolId);
        }
        if (!LibPoolMembership.isMember(positionKey, params.quotePoolId)) {
            revert PoolMembershipRequired(positionKey, params.quotePoolId);
        }

        LibFeeIndex.settle(params.underlyingPoolId, positionKey);
        LibActiveCreditIndex.settle(params.underlyingPoolId, positionKey);
        LibFeeIndex.settle(params.quotePoolId, positionKey);
        LibActiveCreditIndex.settle(params.quotePoolId, positionKey);

        (uint16 createFeeBps, uint16 exerciseFeeBps, uint16 reclaimFeeBps) =
            _resolveFeeBps(cfg, params.useCustomFees, params.createFeeBps, params.exerciseFeeBps, params.reclaimFeeBps);
        _chargeCreateFee(
            positionKey,
            params.underlyingPoolId,
            params.totalSize,
            createFeeBps,
            cfg.defaultCreateFeeFlatWad
        );
        LibDerivativeHelpers._lockCollateral(positionKey, params.underlyingPoolId, params.totalSize);

        seriesId = ++ds.nextFuturesSeriesId;
        DerivativeTypes.FuturesSeries storage series = ds.futuresSeries[seriesId];

        uint64 gracePeriod = ds.futuresReclaimGracePeriod;
        if (gracePeriod == 0) {
            gracePeriod = ds.config.defaultGracePeriodSeconds;
        }

        series.makerPositionKey = positionKey;
        series.makerPositionId = params.positionId;
        series.underlyingPoolId = params.underlyingPoolId;
        series.quotePoolId = params.quotePoolId;
        series.underlyingAsset = underlyingPool.underlying;
        series.quoteAsset = quotePool.underlying;
        series.forwardPrice = params.forwardPrice;
        series.expiry = params.expiry;
        series.totalSize = params.totalSize;
        series.remaining = params.totalSize;
        series.underlyingLocked = params.totalSize;
        series.createFeeBps = createFeeBps;
        series.exerciseFeeBps = exerciseFeeBps;
        series.reclaimFeeBps = reclaimFeeBps;
        series.graceUnlockTime = params.expiry + gracePeriod;
        series.isEuropean = params.isEuropean;
        series.reclaimed = false;

        LibDerivativeStorage.addFuturesSeries(positionKey, seriesId);

        PositionNFT nft = LibDirectHelpers._positionNFT();
        address makerOwner = nft.ownerOf(params.positionId);
        _futuresToken().managerMint(makerOwner, seriesId, params.totalSize, "");

        emit SeriesCreated(
            seriesId,
            positionKey,
            params.positionId,
            params.underlyingPoolId,
            params.quotePoolId,
            series.underlyingAsset,
            series.quoteAsset,
            params.forwardPrice,
            params.expiry,
            params.totalSize,
            params.totalSize,
            series.graceUnlockTime,
            params.isEuropean
        );
    }

    function settleFutures(uint256 seriesId, uint256 amount, address recipient) external payable nonReentrant {
        _settleFutures(seriesId, amount, msg.sender, recipient);
    }

    function settleFuturesFor(
        uint256 seriesId,
        uint256 amount,
        address holder,
        address recipient
    ) external payable nonReentrant {
        _settleFutures(seriesId, amount, holder, recipient);
    }

    function _settleFutures(uint256 seriesId, uint256 amount, address holder, address recipient) internal {
        if (amount == 0) revert Futures_InvalidAmount(amount);
        if (holder == address(0)) revert Futures_InvalidRecipient(holder);
        if (recipient == address(0)) revert Futures_InvalidRecipient(recipient);

        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.FuturesSeries storage series = ds.futuresSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) revert Futures_InvalidSeries(seriesId);
        if (series.reclaimed) revert Futures_Reclaimed(seriesId);
        if (amount > series.remaining) revert Futures_InvalidAmount(amount);

        _validateSettlementWindow(seriesId, series, ds.config.europeanToleranceSeconds);

        FuturesToken token = _futuresToken();
        _requireTokenHolderOrOperator(token, holder, seriesId, amount);
        token.managerBurn(holder, seriesId, amount);

        bytes32 makerKey = series.makerPositionKey;
        LibFeeIndex.settle(series.underlyingPoolId, makerKey);
        LibActiveCreditIndex.settle(series.underlyingPoolId, makerKey);
        LibFeeIndex.settle(series.quotePoolId, makerKey);
        LibActiveCreditIndex.settle(series.quotePoolId, makerKey);

        uint256 quoteAmount = _normalizeQuoteAmount(
            amount,
            series.forwardPrice,
            series.underlyingAsset,
            series.quoteAsset
        );
        if (quoteAmount == 0) revert Futures_InvalidAmount(quoteAmount);
        LibCurrency.assertMsgValue(series.quoteAsset, quoteAmount);

        LibDerivativeHelpers._unlockCollateral(makerKey, series.underlyingPoolId, amount);

        Types.PoolData storage underlyingPool = LibAppStorage.s().pools[series.underlyingPoolId];
        Types.PoolData storage quotePool = LibAppStorage.s().pools[series.quotePoolId];

        uint256 makerUnderlying = underlyingPool.userPrincipal[makerKey];
        if (makerUnderlying < amount) revert InsufficientPrincipal(amount, makerUnderlying);
        if (underlyingPool.trackedBalance < amount) {
            revert InsufficientPrincipal(amount, underlyingPool.trackedBalance);
        }

        underlyingPool.userPrincipal[makerKey] = makerUnderlying - amount;
        underlyingPool.totalDeposits = underlyingPool.totalDeposits >= amount
            ? underlyingPool.totalDeposits - amount
            : 0;
        underlyingPool.trackedBalance -= amount;
        if (LibCurrency.isNative(underlyingPool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        DerivativeTypes.DerivativeConfig storage cfg = LibDerivativeStorage.derivativeStorage().config;
        uint256 exerciseFee = _chargeExerciseFee(
            holder,
            quotePool,
            series.quotePoolId,
            series.quoteAsset,
            quoteAmount,
            series.exerciseFeeBps,
            cfg.defaultExerciseFeeFlatWad
        );
        uint256 netQuote = quoteAmount - exerciseFee;
        quotePool.userPrincipal[makerKey] += netQuote;
        quotePool.totalDeposits += netQuote;

        LibCurrency.transfer(series.underlyingAsset, recipient, amount);

        series.remaining -= amount;
        series.underlyingLocked -= amount;

        emit Settled(seriesId, holder, recipient, amount, quoteAmount);
    }

    function reclaimFutures(uint256 seriesId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.FuturesSeries storage series = ds.futuresSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) revert Futures_InvalidSeries(seriesId);
        if (series.reclaimed) revert Futures_Reclaimed(seriesId);
        if (block.timestamp < series.graceUnlockTime) {
            revert Futures_GracePeriodNotElapsed(seriesId);
        }

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(series.makerPositionId);
        if (positionKey != series.makerPositionKey) {
            revert Futures_InvalidSeries(seriesId);
        }

        uint256 remaining = series.remaining;
        uint256 collateralUnlocked;
        if (remaining > 0) {
            FuturesToken token = _futuresToken();
            uint256 balance = token.balanceOf(msg.sender, seriesId);
            if (balance < remaining) {
                revert Futures_InsufficientBalance(msg.sender, remaining, balance);
            }
            token.managerBurn(msg.sender, seriesId, remaining);

            collateralUnlocked = remaining;
            LibDerivativeHelpers._unlockCollateral(positionKey, series.underlyingPoolId, collateralUnlocked);
            series.underlyingLocked -= collateralUnlocked;
            series.remaining = 0;

            LibFeeIndex.settle(series.underlyingPoolId, positionKey);
            LibActiveCreditIndex.settle(series.underlyingPoolId, positionKey);
            _chargeReclaimFee(
                positionKey,
                series.underlyingPoolId,
                collateralUnlocked,
                series.reclaimFeeBps,
                ds.config.defaultReclaimFeeFlatWad
            );
        }

        series.reclaimed = true;
        LibDerivativeStorage.removeFuturesSeries(positionKey, seriesId);

        emit Reclaimed(seriesId, positionKey, remaining, collateralUnlocked);
    }

    function getFuturesSeries(uint256 seriesId) external view returns (DerivativeTypes.FuturesSeries memory) {
        return LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId];
    }

    function getFuturesCollateral(uint256 seriesId)
        external
        view
        returns (uint256 underlyingLocked, uint256 remaining)
    {
        DerivativeTypes.FuturesSeries storage series = LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId];
        return (series.underlyingLocked, series.remaining);
    }

    function getGraceUnlockTime(uint256 seriesId) external view returns (uint64) {
        return LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId].graceUnlockTime;
    }

    function _futuresToken() internal view returns (FuturesToken token) {
        address tokenAddress = LibDerivativeStorage.derivativeStorage().futuresToken;
        if (tokenAddress == address(0)) revert Futures_TokenNotSet();
        token = FuturesToken(tokenAddress);
    }

    function _requireTokenHolderOrOperator(
        FuturesToken token,
        address holder,
        uint256 seriesId,
        uint256 amount
    ) internal view {
        uint256 balance = token.balanceOf(holder, seriesId);
        if (balance < amount) {
            revert Futures_InsufficientBalance(holder, amount, balance);
        }
        if (msg.sender != holder && !token.isApprovedForAll(holder, msg.sender)) {
            revert Futures_NotTokenHolder(msg.sender, seriesId);
        }
    }

    function _normalizeQuoteAmount(
        uint256 amount,
        uint256 forwardPrice,
        address underlying,
        address quote
    ) internal view returns (uint256) {
        uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();
        return LibDerivativeHelpers._normalizePrice(amount, forwardPrice, underlyingDecimals, quoteDecimals);
    }

    function _validateSettlementWindow(
        uint256 seriesId,
        DerivativeTypes.FuturesSeries storage series,
        uint64 tolerance
    ) internal view {
        if (!series.isEuropean) {
            if (block.timestamp > series.graceUnlockTime) revert Futures_SettlementWindowClosed(seriesId);
            return;
        }

        uint64 lowerBound = series.expiry > tolerance ? series.expiry - tolerance : 0;
        uint64 upperBound = series.expiry + tolerance;
        if (block.timestamp < lowerBound || block.timestamp > upperBound) {
            revert Futures_SettlementWindowClosed(seriesId);
        }
    }

    function _resolveFeeBps(
        DerivativeTypes.DerivativeConfig storage cfg,
        bool useCustomFees,
        uint16 createFeeBps,
        uint16 exerciseFeeBps,
        uint16 reclaimFeeBps
    ) internal view returns (uint16 resolvedCreate, uint16 resolvedExercise, uint16 resolvedReclaim) {
        uint16 minBps = cfg.minFeeBps;
        uint16 maxBps = cfg.maxFeeBps;
        if (useCustomFees) {
            LibDerivativeFees.validateFeeBps(createFeeBps, minBps, maxBps);
            LibDerivativeFees.validateFeeBps(exerciseFeeBps, minBps, maxBps);
            LibDerivativeFees.validateFeeBps(reclaimFeeBps, minBps, maxBps);
            return (createFeeBps, exerciseFeeBps, reclaimFeeBps);
        }
        LibDerivativeFees.validateFeeBps(cfg.defaultCreateFeeBps, minBps, maxBps);
        LibDerivativeFees.validateFeeBps(cfg.defaultExerciseFeeBps, minBps, maxBps);
        LibDerivativeFees.validateFeeBps(cfg.defaultReclaimFeeBps, minBps, maxBps);
        return (cfg.defaultCreateFeeBps, cfg.defaultExerciseFeeBps, cfg.defaultReclaimFeeBps);
    }

    function _chargeCreateFee(
        bytes32 positionKey,
        uint256 poolId,
        uint256 baseAmount,
        uint16 feeBps,
        uint128 flatFeeWad
    ) internal returns (uint256 feeAmount) {
        if (feeBps == 0 && flatFeeWad == 0) {
            return 0;
        }
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        feeAmount = LibDerivativeFees.computeFeeAmount(baseAmount, feeBps, flatFeeWad, pool.underlying);
        LibDerivativeFees.enforceFeeWithinPayment(feeAmount, baseAmount);

        uint256 principal = pool.userPrincipal[positionKey];
        if (principal < feeAmount) revert InsufficientPrincipal(feeAmount, principal);
        pool.userPrincipal[positionKey] = principal - feeAmount;
        pool.totalDeposits -= feeAmount;

        (uint256 toTreasury,,) =
            LibFeeTreasury.accrueWithTreasuryFromPrincipal(pool, poolId, feeAmount, keccak256("FUTURES_CREATE_FEE"));
        if (toTreasury > 0) {
            if (pool.trackedBalance < toTreasury) revert InsufficientPrincipal(toTreasury, pool.trackedBalance);
            pool.trackedBalance -= toTreasury;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
            }
        }
    }

    function _chargeExerciseFee(
        address payer,
        Types.PoolData storage pool,
        uint256 poolId,
        address paymentAsset,
        uint256 paymentAmount,
        uint16 feeBps,
        uint128 flatFeeWad
    ) internal returns (uint256 feeAmount) {
        uint256 received = LibCurrency.pull(paymentAsset, payer, paymentAmount);
        require(received == paymentAmount, "Direct: insufficient amount received");
        pool.trackedBalance += paymentAmount;
        if (feeBps == 0 && flatFeeWad == 0) {
            return 0;
        }
        feeAmount = LibDerivativeFees.computeFeeAmount(paymentAmount, feeBps, flatFeeWad, paymentAsset);
        LibDerivativeFees.enforceFeeWithinPayment(feeAmount, paymentAmount);
        LibFeeTreasury.accrueWithTreasury(pool, poolId, feeAmount, keccak256("FUTURES_EXERCISE_FEE"));
    }

    function _chargeReclaimFee(
        bytes32 positionKey,
        uint256 poolId,
        uint256 baseAmount,
        uint16 feeBps,
        uint128 flatFeeWad
    ) internal returns (uint256 feeAmount) {
        if (feeBps == 0 && flatFeeWad == 0) {
            return 0;
        }
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        feeAmount = LibDerivativeFees.computeFeeAmount(baseAmount, feeBps, flatFeeWad, pool.underlying);
        LibDerivativeFees.enforceFeeWithinPayment(feeAmount, baseAmount);

        uint256 principal = pool.userPrincipal[positionKey];
        if (principal < feeAmount) revert InsufficientPrincipal(feeAmount, principal);
        pool.userPrincipal[positionKey] = principal - feeAmount;
        pool.totalDeposits -= feeAmount;

        (uint256 toTreasury,,) =
            LibFeeTreasury.accrueWithTreasuryFromPrincipal(pool, poolId, feeAmount, keccak256("FUTURES_RECLAIM_FEE"));
        if (toTreasury > 0) {
            if (pool.trackedBalance < toTreasury) revert InsufficientPrincipal(toTreasury, pool.trackedBalance);
            pool.trackedBalance -= toTreasury;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
            }
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {OptionToken} from "../derivatives/OptionToken.sol";
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

error Options_Paused();
error Options_InvalidAmount(uint256 amount);
error Options_InvalidPrice(uint256 strikePrice);
error Options_InvalidExpiry(uint64 expiry);
error Options_InvalidPool(uint256 poolId);
error Options_InvalidAssetPair(address underlying, address strike);
error Options_InvalidSeries(uint256 seriesId);
error Options_ExerciseWindowClosed(uint256 seriesId);
error Options_NotExpired(uint256 seriesId);
error Options_Reclaimed(uint256 seriesId);
error Options_NotTokenHolder(address caller, uint256 seriesId);
error Options_InvalidRecipient(address recipient);
error Options_InsufficientBalance(address holder, uint256 required, uint256 available);
error Options_TokenNotSet();

/// @notice Options facet for covered call and secured put series.
contract OptionsFacet is ReentrancyGuardModifiers {
    event SeriesCreated(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 underlyingPoolId,
        uint256 strikePoolId,
        address underlyingAsset,
        address strikeAsset,
        uint256 strikePrice,
        uint64 expiry,
        uint256 totalSize,
        uint256 collateralLocked,
        bool isCall,
        bool isAmerican
    );

    event Exercised(
        uint256 indexed seriesId,
        address indexed holder,
        address indexed recipient,
        uint256 amount,
        uint256 strikeAmount
    );

    event Reclaimed(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 remainingSize,
        uint256 collateralUnlocked
    );

    event OptionTokenUpdated(address indexed token);
    event OptionsPausedUpdated(bool paused);
    event OptionsFeeConfigUpdated(
        uint16 createFeeBps,
        uint16 exerciseFeeBps,
        uint16 reclaimFeeBps,
        uint128 createFeeFlatWad,
        uint128 exerciseFeeFlatWad,
        uint128 reclaimFeeFlatWad,
        uint16 minFeeBps,
        uint16 maxFeeBps
    );

    function setOptionToken(address token) external {
        LibAccess.enforceOwnerOrTimelock();
        if (token == address(0)) revert Options_TokenNotSet();
        LibDerivativeStorage.derivativeStorage().optionToken = token;
        emit OptionTokenUpdated(token);
    }

    function setOptionsPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDerivativeStorage.derivativeStorage().optionsPaused = paused;
        emit OptionsPausedUpdated(paused);
    }

    function createOptionSeries(DerivativeTypes.CreateOptionSeriesParams calldata params)
        external
        nonReentrant
        returns (uint256 seriesId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.DerivativeConfig storage cfg = ds.config;
        if (ds.optionsPaused) revert Options_Paused();
        if (params.totalSize == 0) revert Options_InvalidAmount(params.totalSize);
        if (params.strikePrice == 0) revert Options_InvalidPrice(params.strikePrice);
        if (params.expiry <= block.timestamp) revert Options_InvalidExpiry(params.expiry);
        if (params.underlyingPoolId == params.strikePoolId) {
            revert Options_InvalidPool(params.underlyingPoolId);
        }

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(params.positionId);

        Types.PoolData storage underlyingPool = LibDirectHelpers._pool(params.underlyingPoolId);
        Types.PoolData storage strikePool = LibDirectHelpers._pool(params.strikePoolId);
        if (underlyingPool.underlying == strikePool.underlying) {
            revert Options_InvalidAssetPair(underlyingPool.underlying, strikePool.underlying);
        }
        if (!LibPoolMembership.isMember(positionKey, params.underlyingPoolId)) {
            revert PoolMembershipRequired(positionKey, params.underlyingPoolId);
        }
        if (!LibPoolMembership.isMember(positionKey, params.strikePoolId)) {
            revert PoolMembershipRequired(positionKey, params.strikePoolId);
        }

        LibFeeIndex.settle(params.underlyingPoolId, positionKey);
        LibActiveCreditIndex.settle(params.underlyingPoolId, positionKey);
        LibFeeIndex.settle(params.strikePoolId, positionKey);
        LibActiveCreditIndex.settle(params.strikePoolId, positionKey);

        uint256 collateralLocked;
        uint256 collateralPoolId;
        if (params.isCall) {
            collateralLocked = params.totalSize;
            collateralPoolId = params.underlyingPoolId;
        } else {
            collateralLocked = _normalizeStrikeAmount(
                params.totalSize,
                params.strikePrice,
                underlyingPool.underlying,
                strikePool.underlying
            );
            if (collateralLocked == 0) revert Options_InvalidAmount(collateralLocked);
            collateralPoolId = params.strikePoolId;
        }

        (uint16 createFeeBps, uint16 exerciseFeeBps, uint16 reclaimFeeBps) =
            _resolveFeeBps(cfg, params.useCustomFees, params.createFeeBps, params.exerciseFeeBps, params.reclaimFeeBps);
        _chargeCreateFee(positionKey, collateralPoolId, collateralLocked, createFeeBps, cfg.defaultCreateFeeFlatWad);
        LibDerivativeHelpers._lockCollateral(positionKey, collateralPoolId, collateralLocked);

        seriesId = ++ds.nextOptionSeriesId;
        DerivativeTypes.OptionSeries storage series = ds.optionSeries[seriesId];
        series.makerPositionKey = positionKey;
        series.makerPositionId = params.positionId;
        series.underlyingPoolId = params.underlyingPoolId;
        series.strikePoolId = params.strikePoolId;
        series.underlyingAsset = underlyingPool.underlying;
        series.strikeAsset = strikePool.underlying;
        series.strikePrice = params.strikePrice;
        series.expiry = params.expiry;
        series.totalSize = params.totalSize;
        series.remaining = params.totalSize;
        series.collateralLocked = collateralLocked;
        series.createFeeBps = createFeeBps;
        series.exerciseFeeBps = exerciseFeeBps;
        series.reclaimFeeBps = reclaimFeeBps;
        series.isCall = params.isCall;
        series.isAmerican = params.isAmerican;
        series.reclaimed = false;

        LibDerivativeStorage.addOptionSeries(positionKey, seriesId);

        PositionNFT nft = LibDirectHelpers._positionNFT();
        address makerOwner = nft.ownerOf(params.positionId);
        _optionToken().managerMint(makerOwner, seriesId, params.totalSize, "");

        emit SeriesCreated(
            seriesId,
            positionKey,
            params.positionId,
            params.underlyingPoolId,
            params.strikePoolId,
            series.underlyingAsset,
            series.strikeAsset,
            params.strikePrice,
            params.expiry,
            params.totalSize,
            collateralLocked,
            params.isCall,
            params.isAmerican
        );
    }

    function exerciseOptions(uint256 seriesId, uint256 amount, address recipient) external payable nonReentrant {
        _exerciseOptions(seriesId, amount, msg.sender, recipient);
    }

    function exerciseOptionsFor(
        uint256 seriesId,
        uint256 amount,
        address holder,
        address recipient
    ) external payable nonReentrant {
        _exerciseOptions(seriesId, amount, holder, recipient);
    }

    function _exerciseOptions(uint256 seriesId, uint256 amount, address holder, address recipient) internal {
        if (amount == 0) revert Options_InvalidAmount(amount);
        if (holder == address(0)) revert Options_InvalidRecipient(holder);
        if (recipient == address(0)) revert Options_InvalidRecipient(recipient);

        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.OptionSeries storage series = ds.optionSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) revert Options_InvalidSeries(seriesId);
        if (series.reclaimed) revert Options_Reclaimed(seriesId);
        if (amount > series.remaining) revert Options_InvalidAmount(amount);

        _validateExerciseWindow(seriesId, series, ds.config.europeanToleranceSeconds);

        OptionToken token = _optionToken();
        _requireTokenHolderOrOperator(token, holder, seriesId, amount);
        token.managerBurn(holder, seriesId, amount);

        bytes32 makerKey = series.makerPositionKey;
        LibFeeIndex.settle(series.underlyingPoolId, makerKey);
        LibActiveCreditIndex.settle(series.underlyingPoolId, makerKey);
        LibFeeIndex.settle(series.strikePoolId, makerKey);
        LibActiveCreditIndex.settle(series.strikePoolId, makerKey);

        uint256 strikeAmount = _normalizeStrikeAmount(
            amount,
            series.strikePrice,
            series.underlyingAsset,
            series.strikeAsset
        );
        if (strikeAmount == 0) revert Options_InvalidAmount(strikeAmount);
        LibCurrency.assertMsgValue(
            series.isCall ? series.strikeAsset : series.underlyingAsset,
            series.isCall ? strikeAmount : amount
        );

        if (series.isCall) {
            _exerciseCall(series, makerKey, holder, amount, strikeAmount, recipient);
        } else {
            _exercisePut(series, makerKey, holder, amount, strikeAmount, recipient);
        }

        series.remaining -= amount;
        if (series.isCall) {
            series.collateralLocked -= amount;
        } else {
            series.collateralLocked -= strikeAmount;
        }

        emit Exercised(seriesId, holder, recipient, amount, strikeAmount);
    }

    function reclaimOptions(uint256 seriesId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.OptionSeries storage series = ds.optionSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) revert Options_InvalidSeries(seriesId);
        if (series.reclaimed) revert Options_Reclaimed(seriesId);
        if (block.timestamp <= series.expiry) revert Options_NotExpired(seriesId);

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(series.makerPositionId);
        if (positionKey != series.makerPositionKey) {
            revert Options_InvalidSeries(seriesId);
        }

        uint256 remaining = series.remaining;
        uint256 collateralUnlocked;
        if (remaining > 0) {
            OptionToken token = _optionToken();
            uint256 balance = token.balanceOf(msg.sender, seriesId);
            if (balance < remaining) {
                revert Options_InsufficientBalance(msg.sender, remaining, balance);
            }
            token.managerBurn(msg.sender, seriesId, remaining);

            collateralUnlocked = series.isCall
                ? remaining
                : _normalizeStrikeAmount(
                    remaining,
                    series.strikePrice,
                    series.underlyingAsset,
                    series.strikeAsset
                );

            if (collateralUnlocked == 0) revert Options_InvalidAmount(collateralUnlocked);
            uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
            LibDerivativeHelpers._unlockCollateral(positionKey, collateralPoolId, collateralUnlocked);
            series.collateralLocked -= collateralUnlocked;
            series.remaining = 0;

            LibFeeIndex.settle(collateralPoolId, positionKey);
            LibActiveCreditIndex.settle(collateralPoolId, positionKey);
            _chargeReclaimFee(
                positionKey,
                collateralPoolId,
                collateralUnlocked,
                series.reclaimFeeBps,
                ds.config.defaultReclaimFeeFlatWad
            );
        }

        series.reclaimed = true;
        LibDerivativeStorage.removeOptionSeries(positionKey, seriesId);

        emit Reclaimed(seriesId, positionKey, remaining, collateralUnlocked);
    }

    function getOptionSeries(uint256 seriesId) external view returns (DerivativeTypes.OptionSeries memory) {
        return LibDerivativeStorage.derivativeStorage().optionSeries[seriesId];
    }

    function getOptionSeriesCollateral(uint256 seriesId)
        external
        view
        returns (uint256 collateralLocked, uint256 remaining)
    {
        DerivativeTypes.OptionSeries storage series = LibDerivativeStorage.derivativeStorage().optionSeries[seriesId];
        return (series.collateralLocked, series.remaining);
    }

    function _optionToken() internal view returns (OptionToken token) {
        address tokenAddress = LibDerivativeStorage.derivativeStorage().optionToken;
        if (tokenAddress == address(0)) revert Options_TokenNotSet();
        token = OptionToken(tokenAddress);
    }

    function _requireTokenHolderOrOperator(
        OptionToken token,
        address holder,
        uint256 seriesId,
        uint256 amount
    ) internal view {
        uint256 balance = token.balanceOf(holder, seriesId);
        if (balance < amount) {
            revert Options_InsufficientBalance(holder, amount, balance);
        }
        if (msg.sender != holder && !token.isApprovedForAll(holder, msg.sender)) {
            revert Options_NotTokenHolder(msg.sender, seriesId);
        }
    }

    function _normalizeStrikeAmount(
        uint256 amount,
        uint256 strikePrice,
        address underlying,
        address strike
    ) internal view returns (uint256) {
        uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
        uint8 strikeDecimals = IERC20Metadata(strike).decimals();
        return LibDerivativeHelpers._normalizePrice(amount, strikePrice, underlyingDecimals, strikeDecimals);
    }

    function _validateExerciseWindow(
        uint256 seriesId,
        DerivativeTypes.OptionSeries storage series,
        uint64 tolerance
    ) internal view {
        if (series.isAmerican) {
            if (block.timestamp >= series.expiry) revert Options_ExerciseWindowClosed(seriesId);
            return;
        }

        uint64 lowerBound = series.expiry > tolerance ? series.expiry - tolerance : 0;
        uint64 upperBound = series.expiry + tolerance;
        if (block.timestamp < lowerBound || block.timestamp > upperBound) {
            revert Options_ExerciseWindowClosed(seriesId);
        }
    }

    function _exerciseCall(
        DerivativeTypes.OptionSeries storage series,
        bytes32 makerKey,
        address holder,
        uint256 amount,
        uint256 strikeAmount,
        address recipient
    ) internal {
        LibDerivativeHelpers._unlockCollateral(makerKey, series.underlyingPoolId, amount);

        Types.PoolData storage underlyingPool = LibAppStorage.s().pools[series.underlyingPoolId];
        Types.PoolData storage strikePool = LibAppStorage.s().pools[series.strikePoolId];

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
            strikePool,
            series.strikePoolId,
            series.strikeAsset,
            strikeAmount,
            series.exerciseFeeBps,
            cfg.defaultExerciseFeeFlatWad
        );
        uint256 netStrike = strikeAmount - exerciseFee;
        strikePool.userPrincipal[makerKey] += netStrike;
        strikePool.totalDeposits += netStrike;

        LibCurrency.transfer(series.underlyingAsset, recipient, amount);
    }

    function _exercisePut(
        DerivativeTypes.OptionSeries storage series,
        bytes32 makerKey,
        address holder,
        uint256 amount,
        uint256 strikeAmount,
        address recipient
    ) internal {
        LibDerivativeHelpers._unlockCollateral(makerKey, series.strikePoolId, strikeAmount);

        Types.PoolData storage underlyingPool = LibAppStorage.s().pools[series.underlyingPoolId];
        Types.PoolData storage strikePool = LibAppStorage.s().pools[series.strikePoolId];

        DerivativeTypes.DerivativeConfig storage cfg = LibDerivativeStorage.derivativeStorage().config;
        uint256 exerciseFee = _chargeExerciseFee(
            holder,
            underlyingPool,
            series.underlyingPoolId,
            series.underlyingAsset,
            amount,
            series.exerciseFeeBps,
            cfg.defaultExerciseFeeFlatWad
        );
        uint256 netUnderlying = amount - exerciseFee;
        underlyingPool.userPrincipal[makerKey] += netUnderlying;
        underlyingPool.totalDeposits += netUnderlying;

        uint256 makerStrike = strikePool.userPrincipal[makerKey];
        if (makerStrike < strikeAmount) revert InsufficientPrincipal(strikeAmount, makerStrike);
        if (strikePool.trackedBalance < strikeAmount) {
            revert InsufficientPrincipal(strikeAmount, strikePool.trackedBalance);
        }

        strikePool.userPrincipal[makerKey] = makerStrike - strikeAmount;
        strikePool.totalDeposits = strikePool.totalDeposits >= strikeAmount
            ? strikePool.totalDeposits - strikeAmount
            : 0;
        strikePool.trackedBalance -= strikeAmount;
        if (LibCurrency.isNative(strikePool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= strikeAmount;
        }

        LibCurrency.transfer(series.strikeAsset, recipient, strikeAmount);
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
            LibFeeTreasury.accrueWithTreasuryFromPrincipal(pool, poolId, feeAmount, keccak256("OPTIONS_CREATE_FEE"));
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
        LibFeeTreasury.accrueWithTreasury(pool, poolId, feeAmount, keccak256("OPTIONS_EXERCISE_FEE"));
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
            LibFeeTreasury.accrueWithTreasuryFromPrincipal(pool, poolId, feeAmount, keccak256("OPTIONS_RECLAIM_FEE"));
        if (toTreasury > 0) {
            if (pool.trackedBalance < toTreasury) revert InsufficientPrincipal(toTreasury, pool.trackedBalance);
            pool.trackedBalance -= toTreasury;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
            }
        }
    }
}

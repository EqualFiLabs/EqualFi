// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {Types} from "../libraries/Types.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibDirectRolling} from "../libraries/LibDirectRolling.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import "../libraries/Errors.sol";
import "../libraries/Errors.sol";

/// @notice Governance-minimized admin for parameter updates and timelocked diamond cuts
contract AdminGovernanceFacet {
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryShareUpdated(uint16 oldShareBps, uint16 newShareBps);
    event ActiveCreditShareUpdated(uint16 oldShareBps, uint16 newShareBps);
    event IndexCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event PoolCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event PositionMintFeeUpdated(address indexed oldToken, address indexed newToken, uint256 oldAmount, uint256 newAmount);
    event FoundationReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event DefaultMaintenanceRateUpdated(uint16 oldRateBps, uint16 newRateBps);
    event MaxMaintenanceRateUpdated(uint16 oldMaxBps, uint16 newMaxBps);
    event ActionFeeBoundsUpdated(uint128 oldMin, uint128 oldMax, uint128 newMin, uint128 newMax);
    event ActionFeeConfigUpdated(uint256 indexed pid, bytes32 indexed action, uint128 amount, bool enabled);
    event AumFeeUpdated(uint256 indexed pid, uint16 oldFeeBps, uint16 newFeeBps);
    event PoolDeprecated(uint256 indexed pid, bool deprecated);
    event RollingDelinquencyThresholdsUpdated(uint8 oldDelinquentEpochs, uint8 oldLiquidationEpochs, uint8 newDelinquentEpochs, uint8 newLiquidationEpochs);
    event DefaultPoolConfigUpdated(uint256 fixedTermCount);
    event PoolConfigUpdated(uint256 indexed pid, uint256 fixedTermCount);
    event DerivativeFeeConfigUpdated(
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 createFeeBps,
        uint16 exerciseFeeBps,
        uint16 reclaimFeeBps,
        uint16 ammMakerShareBps,
        uint16 communityMakerShareBps,
        uint16 mamMakerShareBps,
        uint128 createFeeFlatWad,
        uint128 exerciseFeeFlatWad,
        uint128 reclaimFeeFlatWad
    );
    event RollingMinPaymentBpsUpdated(uint16 oldBps, uint16 newBps);
    event DirectRollingConfigUpdated(
        uint32 minPaymentIntervalSeconds,
        uint16 maxPaymentCount,
        uint16 maxUpfrontPremiumBps,
        uint16 minRollingApyBps,
        uint16 maxRollingApyBps,
        uint16 defaultPenaltyBps,
        uint16 minPaymentBps
    );

    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = s().pools[pid];
        require(p.initialized, "EqualFi: pool not initialized");
        return p;
    }

    function _validateDefaultPoolConfig(
        LibAppStorage.AppStorage storage store,
        Types.PoolConfig calldata config
    ) internal view {
        if (config.minDepositAmount == 0) {
            revert InvalidMinimumThreshold("minDepositAmount must be > 0");
        }
        if (config.minLoanAmount == 0) {
            revert InvalidMinimumThreshold("minLoanAmount must be > 0");
        }
        if (config.isCapped && config.depositCap == 0) {
            revert InvalidDepositCap();
        }
        if (config.aumFeeMinBps > config.aumFeeMaxBps) revert InvalidAumFeeBounds();
        if (config.aumFeeMaxBps > 10_000) revert InvalidParameterRange("aumFeeMaxBps > 100%");
        if (config.depositorLTVBps == 0 || config.depositorLTVBps > 10_000) revert InvalidLTVRatio();
        if (config.maintenanceRateBps == 0) {
            revert InvalidMaintenanceRate();
        }
        uint16 maxRate = store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
        if (config.maintenanceRateBps > maxRate) revert InvalidMaintenanceRate();
        if (config.flashLoanFeeBps > 10_000) revert InvalidFlashLoanFee();
        if (config.rollingApyBps > 10_000) revert InvalidAPYRate("rollingApyBps > 100%");
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            if (config.fixedTermConfigs[i].durationSecs == 0) revert InvalidFixedTermDuration();
            if (config.fixedTermConfigs[i].apyBps > 10_000) {
                revert InvalidAPYRate("fixedTermApyBps > 100%");
            }
        }
    }

    function _applyPoolConfig(
        Types.PoolConfig storage target,
        Types.PoolConfig calldata config
    ) internal {
        target.rollingApyBps = config.rollingApyBps;
        target.depositorLTVBps = config.depositorLTVBps;
        target.maintenanceRateBps = config.maintenanceRateBps;
        target.flashLoanFeeBps = config.flashLoanFeeBps;
        target.flashLoanAntiSplit = config.flashLoanAntiSplit;
        target.minDepositAmount = config.minDepositAmount;
        target.minLoanAmount = config.minLoanAmount;
        target.minTopupAmount = config.minTopupAmount;
        target.isCapped = config.isCapped;
        target.depositCap = config.depositCap;
        target.maxUserCount = config.maxUserCount;
        target.aumFeeMinBps = config.aumFeeMinBps;
        target.aumFeeMaxBps = config.aumFeeMaxBps;
        target.borrowFee = config.borrowFee;
        target.repayFee = config.repayFee;
        target.withdrawFee = config.withdrawFee;
        target.flashFee = config.flashFee;
        target.closeRollingFee = config.closeRollingFee;

        delete target.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
    }

    /// @notice Set the global default immutable config used for permissionless pools.
    function setDefaultPoolConfig(Types.PoolConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAppStorage.AppStorage storage store = s();
        _validateDefaultPoolConfig(store, config);
        _applyPoolConfig(store.defaultPoolConfig, config);
        store.defaultPoolConfigSet = true;
        emit DefaultPoolConfigUpdated(config.fixedTermConfigs.length);
    }


    /// @notice Set the AUM fee for a pool within its immutable bounds
    /// @param pid Pool ID
    /// @param feeBps New AUM fee in basis points
    function setAumFee(uint256 pid, uint16 feeBps) external {
        LibAccess.enforceOwnerOrTimelock();
        Types.PoolData storage p = _pool(pid);
        
        // Get immutable bounds
        uint16 minBps = p.poolConfig.aumFeeMinBps;
        uint16 maxBps = p.poolConfig.aumFeeMaxBps;
        
        // Enforce bounds
        if (feeBps < minBps || feeBps > maxBps) {
            revert AumFeeOutOfBounds(feeBps, minBps, maxBps);
        }
        
        // Update fee
        uint16 oldFee = p.currentAumFeeBps;
        p.currentAumFeeBps = feeBps;
        
        emit AumFeeUpdated(pid, oldFee, feeBps);
    }

    /// @notice Override a pool's immutable config after creation (governance only).
    function setPoolConfig(uint256 pid, Types.PoolConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        Types.PoolData storage p = _pool(pid);
        LibAppStorage.AppStorage storage store = s();
        _validateDefaultPoolConfig(store, config);
        _applyPoolConfig(p.poolConfig, config);
        if (p.currentAumFeeBps < config.aumFeeMinBps || p.currentAumFeeBps > config.aumFeeMaxBps) {
            p.currentAumFeeBps = config.aumFeeMinBps;
        }
        emit PoolConfigUpdated(pid, config.fixedTermConfigs.length);
    }

    /// @notice Update global rolling loan delinquency/penalty epoch thresholds
    /// @param delinquentEpochs Epochs after which a loan is considered delinquent
    /// @param penaltyEpochs Epochs after which penalty is allowed (must be >= delinquentEpochs)
    function setRollingDelinquencyThresholds(uint8 delinquentEpochs, uint8 penaltyEpochs) external {
        LibAccess.enforceOwnerOrTimelock();
        if (delinquentEpochs == 0 || penaltyEpochs == 0) revert InvalidParameterRange("epochs == 0");
        if (penaltyEpochs < delinquentEpochs) revert InvalidParameterRange("penalty < delinquent");
        LibAppStorage.AppStorage storage store = s();
        uint8 oldDelinq = store.rollingDelinquencyEpochs == 0
            ? LibAppStorage.DEFAULT_ROLLING_DELINQUENCY_EPOCHS
            : store.rollingDelinquencyEpochs;
        uint8 oldLiq = store.rollingPenaltyEpochs == 0
            ? LibAppStorage.DEFAULT_ROLLING_PENALTY_EPOCHS
            : store.rollingPenaltyEpochs;
        store.rollingDelinquencyEpochs = delinquentEpochs;
        store.rollingPenaltyEpochs = penaltyEpochs;
        emit RollingDelinquencyThresholdsUpdated(oldDelinq, oldLiq, delinquentEpochs, penaltyEpochs);
    }

    /// @notice Set minimum rolling loan payment size as a percent of remaining principal (bps).
    function setRollingMinPaymentBps(uint16 minPaymentBps) external {
        LibAccess.enforceOwnerOrTimelock();
        if (minPaymentBps > 10_000) revert InvalidParameterRange("minPaymentBps > 100%");
        LibAppStorage.AppStorage storage store = s();
        uint16 oldBps = store.rollingMinPaymentBps;
        store.rollingMinPaymentBps = minPaymentBps;
        emit RollingMinPaymentBpsUpdated(oldBps, minPaymentBps);
    }

    /// @notice Set rolling-direct configuration bounds for offer validation.
    function setDirectRollingConfig(DirectTypes.DirectRollingConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDirectRolling.validateRollingConfig(config);
        LibDirectStorage.directStorage().rollingConfig = config;
        emit DirectRollingConfigUpdated(
            config.minPaymentIntervalSeconds,
            config.maxPaymentCount,
            config.maxUpfrontPremiumBps,
            config.minRollingApyBps,
            config.maxRollingApyBps,
            config.defaultPenaltyBps,
            config.minPaymentBps
        );
    }
    
    /// @notice Mark a pool as deprecated (UI guidance only, does not affect functionality)
    /// @param pid Pool ID
    /// @param deprecated Whether the pool should be marked as deprecated
    function setPoolDeprecated(uint256 pid, bool deprecated) external {
        LibAccess.enforceOwnerOrTimelock();
        Types.PoolData storage p = _pool(pid);
        
        // Update deprecated flag
        p.deprecated = deprecated;
        
        emit PoolDeprecated(pid, deprecated);
    }
    
    /// @notice address of AUM reciever.  Can be the same as treasury but has a dedicated path.
    function setFoundationReceiver(address receiver) external {
        LibAccess.enforceOwnerOrTimelock();
        require(receiver != address(0), "EqualFi: receiver=0");
        LibAppStorage.AppStorage storage store = s();
        address old = store.foundationReceiver;
        store.foundationReceiver = receiver;
        emit FoundationReceiverUpdated(old, receiver);
    }

    function setDefaultMaintenanceRateBps(uint16 rateBps) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAppStorage.AppStorage storage store = s();
        uint16 maxRate = _maxMaintenanceRate(store);
        require(rateBps <= maxRate, "EqualFi: rate>max");
        uint16 old = store.defaultMaintenanceRateBps;
        store.defaultMaintenanceRateBps = rateBps;
        emit DefaultMaintenanceRateUpdated(old, rateBps);
    }

    function setMaxMaintenanceRateBps(uint16 maxRateBps) external {
        LibAccess.enforceOwnerOrTimelock();
        require(maxRateBps > 0, "EqualFi: max=0");
        LibAppStorage.AppStorage storage store = s();
        uint16 old = _maxMaintenanceRate(store);
        store.maxMaintenanceRateBps = maxRateBps;
        emit MaxMaintenanceRateUpdated(old, maxRateBps);
    }



    /// @notice Set the global treasury address for fee diversion.
    function setTreasury(address treasury) external {
        LibAccess.enforceOwnerOrTimelock();
        require(treasury != address(0), "EqualFi: treasury=0");
        LibAppStorage.AppStorage storage store = s();
        address old = LibAppStorage.treasuryAddress(store);
        store.treasury = treasury;
        emit TreasuryUpdated(old, treasury);
    }

    /// @notice Configure the treasury share (in basis points) of fees routed through the split helper.
    function setTreasuryShareBps(uint16 shareBps) external {
        LibAccess.enforceOwnerOrTimelock();
        require(shareBps <= 10_000, "EqualFi: share>100%");
        LibAppStorage.AppStorage storage store = s();
        uint16 activeShare = LibAppStorage.activeCreditSplitBps(store);
        require(shareBps + activeShare <= 10_000, "EqualFi: splits>100%");
        uint16 oldShare = LibAppStorage.treasurySplitBps(store);
        store.treasuryShareBps = shareBps;
        store.treasuryShareConfigured = true;
        emit TreasuryShareUpdated(oldShare, shareBps);
    }

    /// @notice Configure the active credit index share (in basis points) of fees routed through the split helper.
    function setActiveCreditShareBps(uint16 shareBps) external {
        LibAccess.enforceOwnerOrTimelock();
        require(shareBps <= 10_000, "EqualFi: share>100%");
        LibAppStorage.AppStorage storage store = s();
        uint16 treasuryShare = LibAppStorage.treasurySplitBps(store);
        require(shareBps + treasuryShare <= 10_000, "EqualFi: splits>100%");
        uint16 oldShare = LibAppStorage.activeCreditSplitBps(store);
        store.activeCreditShareBps = shareBps;
        store.activeCreditShareConfigured = true;
        emit ActiveCreditShareUpdated(oldShare, shareBps);
    }

    /// @notice Configure global min/max bounds for per-action flat fees.
    function setActionFeeBounds(uint128 minAmount, uint128 maxAmount) external {
        LibAccess.enforceOwnerOrTimelock();
        require(minAmount <= maxAmount, "EqualFi: invalid fee bounds");
        require(maxAmount > 0, "EqualFi: max=0");
        LibAppStorage.AppStorage storage store = s();
        uint128 oldMin = store.actionFeeMin;
        uint128 oldMax = store.actionFeeMax;
        store.actionFeeMin = minAmount;
        store.actionFeeMax = maxAmount;
        store.actionFeeBoundsSet = true;
        emit ActionFeeBoundsUpdated(oldMin, oldMax, minAmount, maxAmount);
    }

    /// @notice Configure the flat fee amount for a pool/action pair.
    function setActionFeeConfig(uint256 pid, bytes32 action, uint128 amount, bool enabled) external {
        LibAccess.enforceOwnerOrTimelock();
        Types.PoolData storage p = _pool(pid);
        LibAppStorage.AppStorage storage store = s();
        if (enabled) {
            require(store.actionFeeBoundsSet, "EqualFi: fee bounds unset");
            require(amount >= store.actionFeeMin && amount <= store.actionFeeMax, "EqualFi: fee out of bounds");
        }
        Types.ActionFeeConfig storage cfg = p.actionFees[action];
        cfg.amount = amount;
        cfg.enabled = enabled;
        emit ActionFeeConfigUpdated(pid, action, amount, enabled);
    }

    function setDerivativeFeeConfig(
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 createFeeBps,
        uint16 exerciseFeeBps,
        uint16 reclaimFeeBps,
        uint16 ammMakerShareBps,
        uint16 communityMakerShareBps,
        uint16 mamMakerShareBps,
        uint128 createFeeFlatWad,
        uint128 exerciseFeeFlatWad,
        uint128 reclaimFeeFlatWad
    ) external {
        LibAccess.enforceOwnerOrTimelock();
        if (minFeeBps > maxFeeBps) revert InvalidParameterRange("minFeeBps > maxFeeBps");
        if (maxFeeBps > 10_000) revert InvalidParameterRange("maxFeeBps > 100%");
        if (createFeeBps < minFeeBps || createFeeBps > maxFeeBps) {
            revert InvalidParameterRange("createFeeBps out of bounds");
        }
        if (exerciseFeeBps < minFeeBps || exerciseFeeBps > maxFeeBps) {
            revert InvalidParameterRange("exerciseFeeBps out of bounds");
        }
        if (reclaimFeeBps < minFeeBps || reclaimFeeBps > maxFeeBps) {
            revert InvalidParameterRange("reclaimFeeBps out of bounds");
        }
        if (ammMakerShareBps > 10_000) revert InvalidParameterRange("ammMakerShareBps > 100%");
        if (communityMakerShareBps > 10_000) revert InvalidParameterRange("communityMakerShareBps > 100%");
        if (mamMakerShareBps > 10_000) revert InvalidParameterRange("mamMakerShareBps > 100%");

        DerivativeTypes.DerivativeConfig storage cfg = LibDerivativeStorage.derivativeStorage().config;
        cfg.minFeeBps = minFeeBps;
        cfg.maxFeeBps = maxFeeBps;
        cfg.defaultCreateFeeBps = createFeeBps;
        cfg.defaultExerciseFeeBps = exerciseFeeBps;
        cfg.defaultReclaimFeeBps = reclaimFeeBps;
        cfg.ammMakerShareBps = ammMakerShareBps;
        cfg.communityMakerShareBps = communityMakerShareBps;
        cfg.mamMakerShareBps = mamMakerShareBps;
        cfg.defaultCreateFeeFlatWad = createFeeFlatWad;
        cfg.defaultExerciseFeeFlatWad = exerciseFeeFlatWad;
        cfg.defaultReclaimFeeFlatWad = reclaimFeeFlatWad;

        emit DerivativeFeeConfigUpdated(
            minFeeBps,
            maxFeeBps,
            createFeeBps,
            exerciseFeeBps,
            reclaimFeeBps,
            ammMakerShareBps,
            communityMakerShareBps,
            mamMakerShareBps,
            createFeeFlatWad,
            exerciseFeeFlatWad,
            reclaimFeeFlatWad
        );
    }

    /// @notice Update the protocol fee receiver for EqualIndex flows.
    function setProtocolFeeReceiver(address newReceiver) external {
        LibAccess.enforceOwnerOrTimelock();
        if (newReceiver == address(0)) revert InvalidFeeReceiver();
        LibEqualIndex.s().protocolFeeReceiver = newReceiver;
        emit LibEqualIndex.ProtocolFeeReceiverUpdated(newReceiver);
    }

    function setIndexCreationFee(uint256 newFee) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAppStorage.AppStorage storage store = s();
        uint256 old = store.indexCreationFee;
        store.indexCreationFee = newFee;
        emit IndexCreationFeeUpdated(old, newFee);
    }

    function setPoolCreationFee(uint256 newFee) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAppStorage.AppStorage storage store = s();
        uint256 old = store.poolCreationFee;
        store.poolCreationFee = newFee;
        emit PoolCreationFeeUpdated(old, newFee);
    }

    function setPositionMintFee(address feeToken, uint256 feeAmount) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAppStorage.AppStorage storage store = s();
        address oldToken = store.positionMintFeeToken;
        uint256 oldAmount = store.positionMintFeeAmount;
        store.positionMintFeeToken = feeToken;
        store.positionMintFeeAmount = feeAmount;
        emit PositionMintFeeUpdated(oldToken, feeToken, oldAmount, feeAmount);
    }

    /// @notice Timelock/owner controlled diamond cut passthrough
    function executeDiamondCut(IDiamondCut.FacetCut[] calldata cuts, address init, bytes calldata data) external {
        LibAccess.enforceOwnerOrTimelock();
        IDiamondCut(address(this)).diamondCut(cuts, init, data);
    }

    function _maxMaintenanceRate(LibAppStorage.AppStorage storage store) internal view returns (uint16) {
        return store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
    }
}

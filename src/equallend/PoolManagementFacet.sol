// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";

/// @notice Pool creation and initialization with fee-based access control.
contract PoolManagementFacet {
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_FLASH = keccak256("ACTION_FLASH");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");
    bytes32 internal constant ACTION_CLOSE_ROLLING = keccak256("ACTION_CLOSE_ROLLING");

    event PoolInitialized(
        uint256 indexed pid,
        address indexed underlying,
        Types.PoolConfig config
    );

    event PoolInitializedManaged(
        uint256 indexed pid,
        address indexed underlying,
        address indexed manager,
        Types.ManagedPoolConfig config
    );

    event ManagedConfigUpdated(uint256 indexed pid, string parameter, bytes oldValue, bytes newValue);
    event WhitelistUpdated(uint256 indexed pid, bytes32 indexed user, bool added);
    event WhitelistToggled(uint256 indexed pid, bool enabled);
    event ManagerTransferred(uint256 indexed pid, address indexed oldManager, address indexed newManager);
    event ManagerRenounced(uint256 indexed pid, address indexed formerManager);

    /// @notice Initialize a new pool with immutable configuration and action fees
    /// @param pid Pool ID (must be unused)
    /// @param underlying ERC20 token address
    /// @param config Immutable pool configuration
    /// @param actionFees Action fees for the pool (can be overridden later by admin)
    function initPoolWithActionFees(
        uint256 pid,
        address underlying,
        Types.PoolConfig calldata config,
        Types.ActionFeeSet calldata actionFees
    ) external payable {
        LibAccess.enforceOwnerOrTimelock();
        Types.PoolConfig memory localConfig = config;
        _initPoolInternal(pid, underlying, localConfig, actionFees, false);
    }

    /// @notice Initialize a new pool with immutable configuration (backward compatibility)
    /// @param pid Pool ID (must be unused)
    /// @param underlying ERC20 token address
    /// @param config Immutable pool configuration
    function initPool(
        uint256 pid,
        address underlying,
        Types.PoolConfig calldata config
    ) external payable {
        LibAccess.enforceOwnerOrTimelock();
        Types.ActionFeeSet memory emptyFees; // All fees disabled by default
        Types.PoolConfig memory localConfig = config;
        _initPoolInternal(pid, underlying, localConfig, emptyFees, false);
    }

    /// @notice Initialize a new pool using global defaults (permissionless path).
    /// @param underlying ERC20 token address
    /// @return pid Pool ID (existing if already initialized for token)
    function initPool(address underlying) external payable returns (uint256 pid) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (!store.defaultPoolConfigSet) revert DefaultPoolConfigNotSet();

        uint256 existingPid = store.permissionlessPoolForToken[underlying];
        if (existingPid != 0) {
            revert PermissionlessPoolAlreadyInitialized(underlying, existingPid);
        }

        pid = _nextPoolId(store);
        (Types.PoolConfig memory config, Types.ActionFeeSet memory fees) =
            _defaultPoolConfig(store);
        _initPoolInternal(pid, underlying, config, fees, false);
    }

    /// @notice Internal pool initialization with action fees
    function _initPoolInternal(
        uint256 pid,
        address underlying,
        Types.PoolConfig memory config,
        Types.ActionFeeSet memory actionFees,
        bool bypassFee
    ) private {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();

        // Handle fee payment (admin vs non-admin)
        bool isGov = LibAccess.isOwnerOrTimelock(msg.sender);
        bool registerPermissionless = !isGov;
        if (!bypassFee) {
            if (isGov) {
                if (msg.value != 0) revert InsufficientPoolCreationFee(0, msg.value);
            } else {
                uint256 fee = store.poolCreationFee;
                if (fee == 0) revert InsufficientPoolCreationFee(1, 0); // Permissionless creation disabled
                if (msg.value != fee) revert InsufficientPoolCreationFee(fee, msg.value);
                address treasury = LibAppStorage.treasuryAddress(store);
                if (treasury == address(0)) revert TreasuryNotSet();
                (bool sent,) = treasury.call{value: fee}("");
                if (!sent) revert PoolCreationFeeTransferFailed();
            }
        } else {
            registerPermissionless = true;
        }

        // Validate pool doesn't already exist
        Types.PoolData storage p = store.pools[pid];
        if (p.initialized) revert PoolAlreadyExists(pid);

        if (registerPermissionless) {
            uint256 existingPid = store.permissionlessPoolForToken[underlying];
            if (existingPid != 0) {
                revert PermissionlessPoolAlreadyInitialized(underlying, existingPid);
            }
        }

        // Validate minimum thresholds are non-zero
        if (config.minDepositAmount == 0) {
            revert InvalidMinimumThreshold("minDepositAmount must be > 0");
        }
        if (config.minLoanAmount == 0) {
            revert InvalidMinimumThreshold("minLoanAmount must be > 0");
        }

        // Validate deposit cap if capped
        if (config.isCapped && config.depositCap == 0) {
            revert InvalidDepositCap();
        }

        // Validate AUM fee bounds
        if (config.aumFeeMinBps > config.aumFeeMaxBps) revert InvalidAumFeeBounds();
        if (config.aumFeeMaxBps > 10_000) revert InvalidParameterRange("aumFeeMaxBps > 100%");

        // Validate LTV and CR ranges
        if (config.depositorLTVBps == 0 || config.depositorLTVBps > 10_000) revert InvalidLTVRatio();

        // Validate maintenance rate
        uint16 maxRate = store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
        uint16 maintenanceRate = config.maintenanceRateBps;
        if (maintenanceRate == 0) {
            // Use default if not specified
            maintenanceRate = store.defaultMaintenanceRateBps;
            if (maintenanceRate == 0) {
                maintenanceRate = maxRate;
            }
        }
        if (maintenanceRate > maxRate) revert InvalidMaintenanceRate();

        // Validate flash loan fee
        if (config.flashLoanFeeBps > 10_000) revert InvalidFlashLoanFee();

        // Validate APY rates
        if (config.rollingApyBps > 10_000) revert InvalidAPYRate("rollingApyBps > 100%");

        _validateFixedTermConfigsMemory(config.fixedTermConfigs);

        // Store underlying address and asset lookup
        p.underlying = underlying;
        p.initialized = true;
        store.assetToPoolId[underlying] = pid;
        if (registerPermissionless) {
            store.permissionlessPoolForToken[underlying] = pid;
        }

        // Store complete immutable configuration
        p.poolConfig.rollingApyBps = config.rollingApyBps;
        p.poolConfig.depositorLTVBps = config.depositorLTVBps;
        p.poolConfig.maintenanceRateBps = maintenanceRate;
        p.poolConfig.flashLoanFeeBps = config.flashLoanFeeBps;
        p.poolConfig.flashLoanAntiSplit = config.flashLoanAntiSplit;
        p.poolConfig.minDepositAmount = config.minDepositAmount;
        p.poolConfig.minLoanAmount = config.minLoanAmount;
        p.poolConfig.minTopupAmount = config.minTopupAmount;
        p.poolConfig.isCapped = config.isCapped;
        p.poolConfig.depositCap = config.depositCap;
        p.poolConfig.maxUserCount = config.maxUserCount;
        p.poolConfig.aumFeeMinBps = config.aumFeeMinBps;
        p.poolConfig.aumFeeMaxBps = config.aumFeeMaxBps;

        // Store fixed term configs
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            p.poolConfig.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }

        // Store action fees in immutable config
        p.poolConfig.borrowFee = actionFees.borrowFee;
        p.poolConfig.repayFee = actionFees.repayFee;
        p.poolConfig.withdrawFee = actionFees.withdrawFee;
        p.poolConfig.flashFee = actionFees.flashFee;
        p.poolConfig.closeRollingFee = actionFees.closeRollingFee;

        // Initialize currentAumFeeBps to a value within bounds (default to minimum)
        p.currentAumFeeBps = config.aumFeeMinBps;

        // Initialize operational state
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        // Increment poolCount to track highest initialized pool
        if (pid >= store.poolCount) {
            store.poolCount = pid + 1;
        }

        emit PoolInitialized(pid, underlying, config);
    }

    function _nextPoolId(LibAppStorage.AppStorage storage store) private view returns (uint256 pid) {
        pid = store.poolCount;
        if (pid == 0) {
            pid = 1;
        }
        while (store.pools[pid].initialized) {
            pid++;
        }
    }

    function _defaultPoolConfig(LibAppStorage.AppStorage storage store)
        private
        view
        returns (Types.PoolConfig memory config, Types.ActionFeeSet memory actionFees)
    {
        Types.PoolConfig storage defaults = store.defaultPoolConfig;
        config.rollingApyBps = defaults.rollingApyBps;
        config.depositorLTVBps = defaults.depositorLTVBps;
        config.maintenanceRateBps = defaults.maintenanceRateBps;
        config.flashLoanFeeBps = defaults.flashLoanFeeBps;
        config.flashLoanAntiSplit = defaults.flashLoanAntiSplit;
        config.minDepositAmount = defaults.minDepositAmount;
        config.minLoanAmount = defaults.minLoanAmount;
        config.minTopupAmount = defaults.minTopupAmount;
        config.isCapped = defaults.isCapped;
        config.depositCap = defaults.depositCap;
        config.maxUserCount = defaults.maxUserCount;
        config.aumFeeMinBps = defaults.aumFeeMinBps;
        config.aumFeeMaxBps = defaults.aumFeeMaxBps;
        config.borrowFee = defaults.borrowFee;
        config.repayFee = defaults.repayFee;
        config.withdrawFee = defaults.withdrawFee;
        config.flashFee = defaults.flashFee;
        config.closeRollingFee = defaults.closeRollingFee;

        uint256 termCount = defaults.fixedTermConfigs.length;
        config.fixedTermConfigs = new Types.FixedTermConfig[](termCount);
        for (uint256 i = 0; i < termCount; i++) {
            config.fixedTermConfigs[i] = defaults.fixedTermConfigs[i];
        }

        actionFees.borrowFee = defaults.borrowFee;
        actionFees.repayFee = defaults.repayFee;
        actionFees.withdrawFee = defaults.withdrawFee;
        actionFees.flashFee = defaults.flashFee;
        actionFees.closeRollingFee = defaults.closeRollingFee;
    }

    /// @notice Initialize a new managed pool with mutable configuration and whitelist gating
    /// @param pid Pool ID (must be unused)
    /// @param underlying ERC20 token address
    /// @param config Managed pool configuration
    function initManagedPool(
        uint256 pid,
        address underlying,
        Types.ManagedPoolConfig calldata config
    ) external payable {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();

        if (store.assetToPoolId[underlying] == 0) {
            if (!store.defaultPoolConfigSet) revert DefaultPoolConfigNotSet();
            _autoCreateBasePool(store, underlying);
        }

        // Managed pool creation always requires the managedPoolCreationFee
        uint256 fee = store.managedPoolCreationFee;
        if (fee == 0) revert ManagedPoolCreationDisabled();
        if (msg.value != fee) revert InsufficientManagedPoolCreationFee(fee, msg.value);
        address treasury = LibAppStorage.treasuryAddress(store);
        if (treasury == address(0)) revert InvalidTreasuryAddress();
        (bool sent,) = treasury.call{value: fee}("");
        if (!sent) revert PoolCreationFeeTransferFailed();

        // Validate pool doesn't already exist
        Types.PoolData storage p = store.pools[pid];
        if (p.initialized) revert PoolAlreadyExists(pid);

        // Validate minimum thresholds are non-zero
        if (config.minDepositAmount == 0) {
            revert InvalidMinimumThreshold("minDepositAmount must be > 0");
        }
        if (config.minLoanAmount == 0) {
            revert InvalidMinimumThreshold("minLoanAmount must be > 0");
        }

        // Validate deposit cap if capped
        if (config.isCapped && config.depositCap == 0) {
            revert InvalidDepositCap();
        }

        // Validate AUM fee bounds
        if (config.aumFeeMinBps > config.aumFeeMaxBps) revert InvalidAumFeeBounds();
        if (config.aumFeeMaxBps > 10_000) revert InvalidParameterRange("aumFeeMaxBps > 100%");

        // Validate LTV and CR ranges
        if (config.depositorLTVBps == 0 || config.depositorLTVBps > 10_000) revert InvalidLTVRatio();

        _validateFixedTermConfigsCalldata(config.fixedTermConfigs);

        // Validate maintenance rate with fallback logic
        uint16 maxRate = store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
        uint16 maintenanceRate = config.maintenanceRateBps;
        if (maintenanceRate == 0) {
            maintenanceRate = store.defaultMaintenanceRateBps;
            if (maintenanceRate == 0) {
                maintenanceRate = maxRate;
            }
        }
        if (maintenanceRate > maxRate) revert InvalidMaintenanceRate();

        // Validate flash loan fee
        if (config.flashLoanFeeBps > 10_000) revert InvalidFlashLoanFee();

        if (config.manager != address(0) && config.manager != msg.sender) {
            revert InvalidManagedPoolConfig("manager must be msg.sender or zero");
        }
        if (!config.whitelistEnabled) {
            revert InvalidManagedPoolConfig("whitelistEnabled must be true");
        }

        // Validate APY rates
        if (config.rollingApyBps > 10_000) revert InvalidAPYRate("rollingApyBps > 100%");

        // Store core identity
        p.isManagedPool = true;
        p.manager = msg.sender;
        p.underlying = underlying;
        p.initialized = true;
        if (underlying == address(0) && store.assetToPoolId[underlying] == 0) {
            store.assetToPoolId[underlying] = pid;
        }

        // Store managed configuration
        p.managedConfig.rollingApyBps = config.rollingApyBps;
        p.managedConfig.depositorLTVBps = config.depositorLTVBps;
        p.managedConfig.maintenanceRateBps = maintenanceRate;
        p.managedConfig.flashLoanFeeBps = config.flashLoanFeeBps;
        p.managedConfig.flashLoanAntiSplit = config.flashLoanAntiSplit;
        p.managedConfig.minDepositAmount = config.minDepositAmount;
        p.managedConfig.minLoanAmount = config.minLoanAmount;
        p.managedConfig.minTopupAmount = config.minTopupAmount;
        p.managedConfig.isCapped = config.isCapped;
        p.managedConfig.depositCap = config.depositCap;
        p.managedConfig.maxUserCount = config.maxUserCount;
        p.managedConfig.aumFeeMinBps = config.aumFeeMinBps;
        p.managedConfig.aumFeeMaxBps = config.aumFeeMaxBps;
        p.managedConfig.manager = msg.sender;

        _storeFixedTermConfigs(p.managedConfig.fixedTermConfigs, config.fixedTermConfigs);

        // Store action fees
        p.managedConfig.actionFees = config.actionFees;

        // Initialize managed pool state
        p.whitelistEnabled = true;
        p.managedConfig.whitelistEnabled = true;

        // Initialize currentAumFeeBps to a value within bounds (default to minimum)
        p.currentAumFeeBps = config.aumFeeMinBps;

        // Initialize operational state
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        // Increment poolCount to track highest initialized pool
        if (pid >= store.poolCount) {
            store.poolCount = pid + 1;
        }

        Types.ManagedPoolConfig memory emittedConfig = config;
        emittedConfig.manager = msg.sender;
        emittedConfig.whitelistEnabled = true;

        emit PoolInitializedManaged(pid, underlying, msg.sender, emittedConfig);
    }

    function _autoCreateBasePool(LibAppStorage.AppStorage storage store, address underlying)
        private
        returns (uint256 pid)
    {
        pid = _nextPoolId(store);
        (Types.PoolConfig memory config, Types.ActionFeeSet memory fees) = _defaultPoolConfig(store);
        _initPoolInternal(pid, underlying, config, fees, true);
    }

    // ─── Managed pool config setters ──────────────────────

    function setRollingApy(uint256 pid, uint16 apyBps) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (apyBps > 10_000) revert InvalidAPYRate("rollingApyBps > 100%");
        uint16 oldVal = p.managedConfig.rollingApyBps;
        p.managedConfig.rollingApyBps = apyBps;
        _emitManagedUpdate(pid, "rollingApyBps", abi.encode(oldVal), abi.encode(apyBps));
    }

    function setDepositorLTV(uint256 pid, uint16 ltvBps) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (ltvBps == 0 || ltvBps > 10_000) revert InvalidLTVRatio();
        uint16 oldVal = p.managedConfig.depositorLTVBps;
        p.managedConfig.depositorLTVBps = ltvBps;
        _emitManagedUpdate(pid, "depositorLTVBps", abi.encode(oldVal), abi.encode(ltvBps));
    }

    function setMinDepositAmount(uint256 pid, uint256 minDeposit) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (minDeposit == 0) revert InvalidMinimumThreshold("minDepositAmount must be > 0");
        uint256 oldVal = p.managedConfig.minDepositAmount;
        p.managedConfig.minDepositAmount = minDeposit;
        _emitManagedUpdate(pid, "minDepositAmount", abi.encode(oldVal), abi.encode(minDeposit));
    }

    function setMinLoanAmount(uint256 pid, uint256 minLoan) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (minLoan == 0) revert InvalidMinimumThreshold("minLoanAmount must be > 0");
        uint256 oldVal = p.managedConfig.minLoanAmount;
        p.managedConfig.minLoanAmount = minLoan;
        _emitManagedUpdate(pid, "minLoanAmount", abi.encode(oldVal), abi.encode(minLoan));
    }

    function setMinTopupAmount(uint256 pid, uint256 minTopup) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (minTopup == 0) revert InvalidMinimumThreshold("minTopupAmount must be > 0");
        uint256 oldVal = p.managedConfig.minTopupAmount;
        p.managedConfig.minTopupAmount = minTopup;
        _emitManagedUpdate(pid, "minTopupAmount", abi.encode(oldVal), abi.encode(minTopup));
    }

    function setDepositCap(uint256 pid, uint256 cap) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (cap == 0) revert InvalidDepositCap();
        uint256 oldVal = p.managedConfig.depositCap;
        p.managedConfig.depositCap = cap;
        _emitManagedUpdate(pid, "depositCap", abi.encode(oldVal), abi.encode(cap));
    }

    function setIsCapped(uint256 pid, bool isCapped) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (isCapped && p.managedConfig.depositCap == 0) revert InvalidDepositCap();
        bool oldVal = p.managedConfig.isCapped;
        p.managedConfig.isCapped = isCapped;
        _emitManagedUpdate(pid, "isCapped", abi.encode(oldVal), abi.encode(isCapped));
    }

    function setMaxUserCount(uint256 pid, uint256 maxUsers) external {
        Types.PoolData storage p = _enforceManager(pid);
        uint256 oldVal = p.managedConfig.maxUserCount;
        p.managedConfig.maxUserCount = maxUsers;
        _emitManagedUpdate(pid, "maxUserCount", abi.encode(oldVal), abi.encode(maxUsers));
    }

    function setMaintenanceRate(uint256 pid, uint16 rateBps) external {
        Types.PoolData storage p = _enforceManager(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint16 maxRate = store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
        if (rateBps == 0 || rateBps > maxRate) revert InvalidMaintenanceRate();
        uint16 oldVal = p.managedConfig.maintenanceRateBps;
        p.managedConfig.maintenanceRateBps = rateBps;
        _emitManagedUpdate(pid, "maintenanceRateBps", abi.encode(oldVal), abi.encode(rateBps));
    }

    function setFlashLoanFee(uint256 pid, uint16 feeBps) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (feeBps > 10_000) revert InvalidFlashLoanFee();
        uint16 oldVal = p.managedConfig.flashLoanFeeBps;
        p.managedConfig.flashLoanFeeBps = feeBps;
        _emitManagedUpdate(pid, "flashLoanFeeBps", abi.encode(oldVal), abi.encode(feeBps));
    }

    function setActionFees(uint256 pid, Types.ActionFeeSet calldata actionFees) external {
        Types.PoolData storage p = _enforceManager(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();

        _validateActionFee(store, actionFees.borrowFee.amount);
        _validateActionFee(store, actionFees.repayFee.amount);
        _validateActionFee(store, actionFees.withdrawFee.amount);
        _validateActionFee(store, actionFees.flashFee.amount);
        _validateActionFee(store, actionFees.closeRollingFee.amount);

        Types.ActionFeeSet memory oldVal = p.managedConfig.actionFees;
        p.managedConfig.actionFees = actionFees;

        // Update mutable pool action fees to reflect managed config
        p.actionFees[ACTION_BORROW] = Types.ActionFeeConfig(actionFees.borrowFee.amount, actionFees.borrowFee.enabled);
        p.actionFees[ACTION_REPAY] = Types.ActionFeeConfig(actionFees.repayFee.amount, actionFees.repayFee.enabled);
        p.actionFees[ACTION_WITHDRAW] =
            Types.ActionFeeConfig(actionFees.withdrawFee.amount, actionFees.withdrawFee.enabled);
        p.actionFees[ACTION_FLASH] = Types.ActionFeeConfig(actionFees.flashFee.amount, actionFees.flashFee.enabled);
        p.actionFees[ACTION_CLOSE_ROLLING] =
            Types.ActionFeeConfig(actionFees.closeRollingFee.amount, actionFees.closeRollingFee.enabled);

        _emitManagedUpdate(pid, "actionFees", abi.encode(oldVal), abi.encode(actionFees));
    }

    function _validateFixedTermConfigsMemory(Types.FixedTermConfig[] memory configs) private pure {
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].durationSecs == 0) revert InvalidFixedTermDuration();
            if (configs[i].apyBps > 10_000) revert InvalidAPYRate("fixedTermApyBps > 100%");
        }
    }

    function _validateFixedTermConfigsCalldata(Types.FixedTermConfig[] calldata configs) private pure {
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].durationSecs == 0) revert InvalidFixedTermDuration();
            if (configs[i].apyBps > 10_000) revert InvalidAPYRate("fixedTermApyBps > 100%");
        }
    }

    function _storeFixedTermConfigs(
        Types.FixedTermConfig[] storage target,
        Types.FixedTermConfig[] calldata configs
    ) private {
        for (uint256 i = 0; i < configs.length; i++) {
            target.push(configs[i]);
        }
    }

    // ─── Whitelist management ─────────────────────────────

    function addToWhitelist(uint256 pid, uint256 tokenId) external {
        Types.PoolData storage p = _enforceManager(pid);
        bytes32 positionKey = _positionKeyForToken(pid, tokenId);
        p.whitelist[positionKey] = true;
        emit WhitelistUpdated(pid, positionKey, true);
    }

    function removeFromWhitelist(uint256 pid, uint256 tokenId) external {
        Types.PoolData storage p = _enforceManager(pid);
        bytes32 positionKey = _positionKeyForToken(pid, tokenId);
        p.whitelist[positionKey] = false;
        emit WhitelistUpdated(pid, positionKey, false);
    }

    function setWhitelistEnabled(uint256 pid, bool enabled) external {
        Types.PoolData storage p = _enforceManager(pid);
        bool old = p.whitelistEnabled;
        p.whitelistEnabled = enabled;
        p.managedConfig.whitelistEnabled = enabled;
        emit WhitelistToggled(pid, enabled);
        _emitManagedUpdate(pid, "whitelistEnabled", abi.encode(old), abi.encode(enabled));
    }

    // ─── Manager transfer / renunciation ────────────────

    function transferManager(uint256 pid, address newManager) external {
        Types.PoolData storage p = _enforceManager(pid);
        if (newManager == address(0)) revert InvalidManagerTransfer();
        address oldManager = p.manager;
        p.manager = newManager;
        p.managedConfig.manager = newManager;
        emit ManagerTransferred(pid, oldManager, newManager);
    }

    function renounceManager(uint256 pid) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (!p.isManagedPool) revert PoolNotManaged(pid);
        address currentManager = p.manager;
        if (currentManager == address(0)) revert ManagerAlreadyRenounced();
        if (msg.sender != currentManager) revert NotPoolManager(msg.sender, currentManager);
        address oldManager = currentManager;
        p.manager = address(0);
        p.managedConfig.manager = address(0);
        emit ManagerRenounced(pid, oldManager);
    }

    // ─── Internal helpers ─────────────────────────────────

    function _enforceManager(uint256 pid) internal view returns (Types.PoolData storage p) {
        p = LibAppStorage.s().pools[pid];
        if (!p.isManagedPool) revert PoolNotManaged(pid);
        address manager = p.manager;
        if (manager == address(0)) revert OnlyManagerAllowed();
        if (manager != msg.sender) revert NotPoolManager(msg.sender, manager);
    }

    function _positionKeyForToken(uint256 pid, uint256 tokenId) internal view virtual returns (bytes32 positionKey) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert InvalidManagedPoolConfig("position NFT not set");
        }
        PositionNFT nft = PositionNFT(nftAddr);
        if (nft.getPoolId(tokenId) != pid) {
            revert InvalidManagedPoolConfig("token pool mismatch");
        }
        positionKey = nft.getPositionKey(tokenId);
    }

    function _emitManagedUpdate(uint256 pid, string memory parameter, bytes memory oldVal, bytes memory newVal)
        internal
    {
        emit ManagedConfigUpdated(pid, parameter, oldVal, newVal);
    }

    function _validateActionFee(LibAppStorage.AppStorage storage store, uint128 amount) internal view {
        if (!store.actionFeeBoundsSet) {
            return;
        }
        if (amount < store.actionFeeMin || amount > store.actionFeeMax) {
            revert ActionFeeBoundsViolation(amount, store.actionFeeMin, store.actionFeeMax);
        }
    }
}

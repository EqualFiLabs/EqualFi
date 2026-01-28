// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibMaintenance} from "../libraries/LibMaintenance.sol";
import {Types} from "../libraries/Types.sol";
import {NoPoolForAsset, PoolNotManaged} from "../libraries/Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";

/// @notice Read-only pool and global configuration views
contract ConfigViewFacet {
    struct PoolInfo {
        uint256 poolId;
        address underlying;
        Types.PoolConfig config;
        uint16 currentAumFeeBps;
        uint256 totalDeposits;
        bool deprecated;
    }
    function getPoolConfigSummary(uint256 pid)
        external
        view
        returns (
            bool isCapped,
            uint256 depositCap,
            address underlying,
            uint16 depositorLTVBps,
            uint16 rollingApyBps
        )
    {
        Types.PoolData storage p = _pool(pid);
        return (
            p.poolConfig.isCapped,
            p.poolConfig.depositCap,
            p.underlying,
            p.poolConfig.depositorLTVBps,
            p.poolConfig.rollingApyBps
        );
    }

    function getPoolCaps(uint256 pid) external view returns (bool isCapped, uint256 depositCap) {
        Types.PoolData storage p = _pool(pid);
        isCapped = p.poolConfig.isCapped;
        depositCap = p.poolConfig.depositCap;
    }

    function getMaintenanceState(uint256 pid)
        external
        view
        returns (
            uint16 poolRateBps,
            uint16 defaultRateBps,
            uint64 lastTimestamp,
            uint256 pending,
            uint256 epochLength,
            address foundationReceiver
        )
    {
        Types.PoolData storage p = _pool(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        poolRateBps = p.poolConfig.maintenanceRateBps;
        defaultRateBps = store.defaultMaintenanceRateBps == 0 ? 100 : store.defaultMaintenanceRateBps;
        lastTimestamp = p.lastMaintenanceTimestamp;
        pending = p.pendingMaintenance;
        epochLength = LibMaintenance.epochLength();
        foundationReceiver = store.foundationReceiver;
    }

    function getFlashConfig(uint256 pid) external view returns (uint16 feeBps, bool antiSplit) {
        Types.PoolData storage p = _pool(pid);
        feeBps = p.poolConfig.flashLoanFeeBps;
        antiSplit = p.poolConfig.flashLoanAntiSplit;
    }

    function getPositionMintFee() external view returns (address feeToken, uint256 feeAmount) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        feeToken = store.positionMintFeeToken;
        feeAmount = store.positionMintFeeAmount;
    }

    function getFixedTermConfigs(uint256 pid) external view returns (Types.FixedTermConfig[] memory configs) {
        Types.PoolData storage p = _pool(pid);
        uint256 len = p.poolConfig.fixedTermConfigs.length;
        configs = new Types.FixedTermConfig[](len);
        for (uint256 i; i < len; i++) {
            configs[i] = p.poolConfig.fixedTermConfigs[i];
        }
    }

    function getMinDepositAmount(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = _pool(pid);
        return p.poolConfig.minDepositAmount;
    }

    function getMinLoanAmount(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = _pool(pid);
        return p.poolConfig.minLoanAmount;
    }

    /// @notice Get complete immutable configuration for a pool
    /// @param pid Pool ID
    /// @return config Complete immutable pool configuration
    function getPoolConfig(uint256 pid) external view returns (Types.PoolConfig memory config) {
        Types.PoolData storage p = _pool(pid);
        config = p.poolConfig;
    }

    /// @notice Get current AUM fee and its immutable bounds
    /// @param pid Pool ID
    /// @return currentFeeBps Current AUM fee in basis points
    /// @return minBps Minimum AUM fee bound (immutable)
    /// @return maxBps Maximum AUM fee bound (immutable)
    function getAumFeeInfo(uint256 pid) 
        external 
        view 
        returns (
            uint16 currentFeeBps,
            uint16 minBps,
            uint16 maxBps
        ) 
    {
        Types.PoolData storage p = _pool(pid);
        currentFeeBps = p.currentAumFeeBps;
        minBps = p.poolConfig.aumFeeMinBps;
        maxBps = p.poolConfig.aumFeeMaxBps;
    }

    /// @notice Check if a pool is marked as deprecated
    /// @param pid Pool ID
    /// @return deprecated True if pool is deprecated (UI guidance only)
    function isPoolDeprecated(uint256 pid) external view returns (bool deprecated) {
        Types.PoolData storage p = _pool(pid);
        deprecated = p.deprecated;
    }

    /// @notice Get comprehensive pool information
    /// @param pid Pool ID
    /// @return underlying Pool's underlying token address
    /// @return config Complete immutable configuration
    /// @return currentAumFeeBps Current AUM fee in basis points
    /// @return totalDeposits Total deposits in the pool
    /// @return deprecated Whether pool is marked deprecated
    function getPoolInfo(uint256 pid) 
        external 
        view 
        returns (
            address underlying,
            Types.PoolConfig memory config,
            uint16 currentAumFeeBps,
            uint256 totalDeposits,
            bool deprecated
        ) 
    {
        Types.PoolData storage p = _pool(pid);
        underlying = p.underlying;
        config = p.poolConfig;
        currentAumFeeBps = p.currentAumFeeBps;
        totalDeposits = p.totalDeposits;
        deprecated = p.deprecated;
    }

    /// @notice Get a paginated list of pool metadata.
    function getPoolList(uint256 offset, uint256 limit)
        external
        view
        returns (PoolInfo[] memory pools, uint256 total)
    {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        total = store.poolCount;
        if (offset >= total) {
            return (new PoolInfo[](0), total);
        }
        uint256 remaining = total - offset;
        if (limit == 0 || limit > remaining) {
            limit = remaining;
        }
        pools = new PoolInfo[](limit);
        uint256 index = 0;
        for (uint256 pid = offset + 1; pid <= total && index < limit; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) {
                continue;
            }
            pools[index] = PoolInfo({
                poolId: pid,
                underlying: p.underlying,
                config: p.poolConfig,
                currentAumFeeBps: p.currentAumFeeBps,
                totalDeposits: p.totalDeposits,
                deprecated: p.deprecated
            });
            index++;
        }
        assembly {
            mstore(pools, index)
        }
    }

    /// @notice Check whether a pool is managed.
    function isManagedPool(uint256 pid) external view returns (bool) {
        Types.PoolData storage p = _pool(pid);
        return p.isManagedPool;
    }

    /// @notice Get the current pool manager (zero if unmanaged or renounced).
    function getPoolManager(uint256 pid) external view returns (address) {
        Types.PoolData storage p = _pool(pid);
        return p.manager;
    }

    /// @notice Check if whitelist gating is enabled for a pool.
    /// @dev Unmanaged pools return false to preserve open access semantics.
    function isWhitelistEnabled(uint256 pid) external view returns (bool) {
        Types.PoolData storage p = _pool(pid);
        return p.isManagedPool ? p.whitelistEnabled : false;
    }

    /// @notice Check whether a user is whitelisted for a pool.
    /// @dev Unmanaged pools always return true to preserve backward compatibility.
    function isWhitelisted(uint256 pid, uint256 tokenId) external view returns (bool) {
        Types.PoolData storage p = _pool(pid);
        if (!p.isManagedPool) {
            return true;
        }
        bytes32 positionKey = _positionKeyForToken(pid, tokenId);
        return p.whitelist[positionKey];
    }

    /// @notice Get the current managed pool configuration for a managed pool.
    function getManagedPoolConfig(uint256 pid) external view returns (Types.ManagedPoolConfig memory config) {
        Types.PoolData storage p = _pool(pid);
        if (!p.isManagedPool) revert PoolNotManaged(pid);
        config = p.managedConfig;
    }

    /// @notice Get the underlying asset address for a pool
    /// @param poolId Pool ID
    /// @return underlying The underlying asset address
    function getPoolUnderlying(uint256 poolId) external view returns (address underlying) {
        Types.PoolData storage p = _pool(poolId);
        underlying = p.underlying;
    }

    /// @notice Get the pool ID for an asset address
    /// @param asset Underlying asset address
    /// @return poolId Pool ID for the asset
    function getPoolIdForAsset(address asset) external view returns (uint256 poolId) {
        poolId = LibAppStorage.s().assetToPoolId[asset];
        if (poolId == 0) {
            revert NoPoolForAsset(asset);
        }
    }

    /// @notice Get rolling loan delinquency and penalty epoch thresholds
    /// @return delinquentEpochs Epochs after which a rolling loan is considered delinquent
    /// @return penaltyEpochs Epochs after which penalty is permitted
    function getRollingDelinquencyThresholds() external view returns (uint8 delinquentEpochs, uint8 penaltyEpochs) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        delinquentEpochs = store.rollingDelinquencyEpochs;
        penaltyEpochs = store.rollingPenaltyEpochs;
        if (delinquentEpochs == 0) {
            delinquentEpochs = LibAppStorage.DEFAULT_ROLLING_DELINQUENCY_EPOCHS;
        }
        if (penaltyEpochs == 0) {
            penaltyEpochs = LibAppStorage.DEFAULT_ROLLING_PENALTY_EPOCHS;
        }
        if (penaltyEpochs < delinquentEpochs) {
            penaltyEpochs = delinquentEpochs;
        }
    }

    /// @notice Get the managed pool system share in basis points.
    function getManagedPoolSystemShareBps() external view returns (uint16 bps) {
        bps = LibAppStorage.managedPoolSystemShareBps(LibAppStorage.s());
    }

    function _positionKeyForToken(uint256 pid, uint256 tokenId) internal view virtual returns (bytes32 positionKey) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert PoolNotManaged(pid);
        }
        PositionNFT nft = PositionNFT(nftAddr);
        if (nft.getPoolId(tokenId) != pid) {
            revert PoolNotManaged(pid);
        }
        positionKey = nft.getPositionKey(tokenId);
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](22);
        selectorsArr[0] = ConfigViewFacet.getPoolConfigSummary.selector;
        selectorsArr[1] = ConfigViewFacet.getPoolCaps.selector;
        selectorsArr[2] = ConfigViewFacet.getMaintenanceState.selector;
        selectorsArr[3] = ConfigViewFacet.getFlashConfig.selector;
        selectorsArr[4] = ConfigViewFacet.getPositionMintFee.selector;
        selectorsArr[5] = ConfigViewFacet.getFixedTermConfigs.selector;
        selectorsArr[6] = ConfigViewFacet.getMinDepositAmount.selector;
        selectorsArr[7] = ConfigViewFacet.getMinLoanAmount.selector;
        selectorsArr[8] = ConfigViewFacet.getPoolConfig.selector;
        selectorsArr[9] = ConfigViewFacet.getAumFeeInfo.selector;
        selectorsArr[10] = ConfigViewFacet.isPoolDeprecated.selector;
        selectorsArr[11] = ConfigViewFacet.getPoolInfo.selector;
        selectorsArr[12] = ConfigViewFacet.getPoolUnderlying.selector;
        selectorsArr[13] = ConfigViewFacet.getPoolIdForAsset.selector;
        selectorsArr[14] = ConfigViewFacet.getRollingDelinquencyThresholds.selector;
        selectorsArr[15] = ConfigViewFacet.getPoolList.selector;
        selectorsArr[16] = ConfigViewFacet.isManagedPool.selector;
        selectorsArr[17] = ConfigViewFacet.getPoolManager.selector;
        selectorsArr[18] = ConfigViewFacet.isWhitelistEnabled.selector;
        selectorsArr[19] = ConfigViewFacet.isWhitelisted.selector;
        selectorsArr[20] = ConfigViewFacet.getManagedPoolConfig.selector;
        selectorsArr[21] = ConfigViewFacet.getManagedPoolSystemShareBps.selector;
    }
}

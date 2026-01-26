// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Shared structs and enums for EqualLend Diamond rebuild
library Types {
    struct ActionFeeConfig {
        uint128 amount;
        bool enabled;
    }
    
    /// @notice Action fee set for pool creation
    struct ActionFeeSet {
        ActionFeeConfig borrowFee;
        ActionFeeConfig repayFee;
        ActionFeeConfig withdrawFee;
        ActionFeeConfig flashFee;
        ActionFeeConfig closeRollingFee;
    }

    struct FixedTermConfig {
        uint40 durationSecs;
        uint16 apyBps;
    }

    /// @notice Pool configuration set at deployment
    /// @dev All parameters in this struct are immutable after pool initialization except action fees
    struct PoolConfig {
        // Interest rates
        uint16 rollingApyBps;           // APY for deposit-backed rolling loans
        // LTV and collateralization
        uint16 depositorLTVBps;         // Max LTV for deposit-backed borrowing
        
        // Maintenance
        uint16 maintenanceRateBps;      // Annual maintenance fee rate
        
        // Flash loans
        uint16 flashLoanFeeBps;         // Flash loan fee in basis points
        bool flashLoanAntiSplit;        // Anti-split protection for flash loans
        
        // Thresholds
        uint256 minDepositAmount;       // Minimum deposit threshold
        uint256 minLoanAmount;          // Minimum loan threshold
        uint256 minTopupAmount;         // Minimum credit line expansion amount
        
        // Caps
        bool isCapped;                  // Whether per-user deposit cap is enforced
        uint256 depositCap;             // Max principal per user (0 = uncapped)
        uint256 maxUserCount;           // Maximum number of users (0 = unlimited)
        
        // AUM fee bounds (immutable)
        uint16 aumFeeMinBps;            // Minimum AUM fee in basis points
        uint16 aumFeeMaxBps;            // Maximum AUM fee in basis points
        
        // Fixed term configs (immutable array)
        FixedTermConfig[] fixedTermConfigs;
        
        // Action fees (set at creation, admin can override post-creation)
        ActionFeeConfig borrowFee;
        ActionFeeConfig repayFee;
        ActionFeeConfig withdrawFee;
        ActionFeeConfig flashFee;
        ActionFeeConfig closeRollingFee;
    }

    /// @notice Managed pool configuration with mutable parameters
    struct ManagedPoolConfig {
        // Interest rates (mutable)
        uint16 rollingApyBps;
        // LTV and collateralization (mutable)
        uint16 depositorLTVBps;

        // Maintenance and flash loan fees (mutable)
        uint16 maintenanceRateBps;
        uint16 flashLoanFeeBps;
        bool flashLoanAntiSplit;

        // Thresholds (mutable)
        uint256 minDepositAmount;
        uint256 minLoanAmount;
        uint256 minTopupAmount;

        // Caps (mutable)
        bool isCapped;
        uint256 depositCap;
        uint256 maxUserCount;

        // AUM fee bounds (immutable)
        uint16 aumFeeMinBps;
        uint16 aumFeeMaxBps;

        // Fixed term configs (immutable array)
        FixedTermConfig[] fixedTermConfigs;

        // Action fees (mutable)
        ActionFeeSet actionFees;

        // Management settings
        address manager;
        bool whitelistEnabled;
    }

    struct RollingCreditLoan {
        uint256 principal;
        uint256 principalRemaining;
        uint40 openedAt;
        uint40 lastPaymentTimestamp;
        uint40 lastAccrualTs;
        uint16 apyBps;
        uint8 missedPayments;
        uint32 paymentIntervalSecs;
        bool depositBacked;
        bool active;
        uint256 principalAtOpen;
    }

    struct FixedTermLoan {
        uint256 principal;
        uint256 principalRemaining;
        uint256 fullInterest;
        uint40 openedAt;
        uint40 expiry;
        uint16 apyBps;
        bytes32 borrower;
        bool closed;
        bool interestRealized;
        uint256 principalAtOpen;
    }

    struct LoanStatusView {
        uint256 principal;
        uint256 principalRemaining;
        uint256 interestAccrued;
        uint256 minimumPaymentDue;
        uint40 lastPaymentTimestamp;
        uint40 nextPaymentDue;
        uint8 missedPayments;
        bool isDelinquent;
        bool eligibleForPenalty;
        bool active;
    }

    /// @notice Position NFT metadata
    struct PositionMetadata {
        uint256 tokenId;
        uint256 poolId;
        address underlying;
        uint40 createdAt;
        address currentOwner;
    }

    /// @notice Encumbrance breakdown for a position within a pool.
    struct PositionEncumbrance {
        uint256 directLocked;
        uint256 directLent;
        uint256 directOfferEscrow;
        uint256 indexEncumbered;
        uint256 totalEncumbered;
    }

    /// @notice Complete state of a Position NFT
    struct PositionState {
        uint256 tokenId;
        uint256 poolId;
        address underlying;
        uint256 principal;
        uint256 accruedYield;
        uint256 feeIndexCheckpoint;
        uint256 maintenanceIndexCheckpoint;
        uint256 externalCollateral;
        RollingCreditLoan rollingLoan;
        uint256[] fixedLoanIds;
        uint256 totalDebt;
        uint256 solvencyRatio; // (principal * 10000) / totalDebt
        bool isDelinquent;
        bool eligibleForPenalty;
    }

    struct PoolData {
        // Core identity
        address underlying;
        bool initialized;
        
        // Pool configuration (stored once, never modified)
        PoolConfig poolConfig;
        
        // Bounded-mutable: AUM fee (within immutable bounds)
        uint16 currentAumFeeBps;
        
        // UI guidance flag (does not affect functionality)
        bool deprecated;
        
        // Operational state (always mutable)
        uint256 totalDeposits;
        uint256 feeIndex;
        uint256 maintenanceIndex;           // cumulative maintenance fee index (reduces principal)
        uint64 lastMaintenanceTimestamp;
        uint256 pendingMaintenance;
        uint256 nextFixedLoanId;
        uint256 userCount;                  // Total number of users with deposits in this pool
        uint256 feeIndexRemainder;          // Per-pool remainder for fee index precision
        uint256 maintenanceIndexRemainder;  // Per-pool remainder for maintenance index precision
        uint256 yieldReserve;               // Backing reserve for accrued yield claims
        uint256 activeCreditIndex;          // Active credit index (parallel to feeIndex)
        uint256 activeCreditIndexRemainder; // Remainder for active credit index precision
        uint256 activeCreditPrincipalTotal; // Sum of active credit principal across debt/encumbrance states
        uint256 activeCreditMaturedTotal;   // Matured principal base for active credit accruals
        uint64 activeCreditPendingStartHour; // Last processed hour for pending principal buckets
        uint8 activeCreditPendingCursor;     // Ring cursor for pending principal buckets
        uint256[24] activeCreditPendingBuckets; // Pending principal scheduled to mature
        uint256 trackedBalance;             // Per-pool tracked token balance for isolation

        // Managed pool state
        bool isManagedPool;
        address manager;
        ManagedPoolConfig managedConfig;
        bool whitelistEnabled;
        mapping(bytes32 => bool) whitelist;
        
        // ─── Per-user ledger ───────────────────────────────
        mapping(bytes32 => uint256) userPrincipal;
        mapping(bytes32 => uint256) userFeeIndex;
        mapping(bytes32 => uint256) userMaintenanceIndex;
        mapping(bytes32 => uint256) userAccruedYield;
        mapping(bytes32 => uint256) externalCollateral;
        // ─── Debt tracking (positionId) ───────────────────
        mapping(uint256 => uint256) sameAssetDebt;
        mapping(uint256 => uint256) crossAssetDebt;
        // ─── Fee base tracking (positionId) ───────────────
        mapping(uint256 => uint256) feeBaseCheckpoint;
        mapping(uint256 => uint256) lastFeeBase;
        // ─── Loan state and indexes ────────────────────────
        mapping(bytes32 => RollingCreditLoan) rollingLoans;
        mapping(uint256 => FixedTermLoan) fixedTermLoans;
        mapping(bytes32 => uint256) activeFixedLoanCount;
        /// @notice Cached sum of principalRemaining across all fixed-term loans for a position
        mapping(bytes32 => uint256) fixedTermPrincipalRemaining;
        mapping(bytes32 => uint256[]) userFixedLoanIds;
        /// @notice Mapping from positionKey => loanId => index in userFixedLoanIds[positionKey]
        /// @dev Enables O(1) loan removal without array scans when used by index-aware helpers.
        mapping(bytes32 => mapping(uint256 => uint256)) loanIdToIndex;
        // ─── Action fee configuration ──────────────────────
        mapping(bytes32 => ActionFeeConfig) actionFees;
        // ─── Active Credit state (positionKey) ─────────────
        mapping(bytes32 => ActiveCreditState) userActiveCreditStateEncumbrance;
        mapping(bytes32 => ActiveCreditState) userActiveCreditStateDebt;
    }

    struct ActiveCreditState {
        uint256 principal;
        uint40 startTime;
        uint256 indexSnapshot;
    }
}

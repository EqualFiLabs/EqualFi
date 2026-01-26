// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// Custom error definitions for EqualLend protocol

// Pool-level thresholds
error DepositBelowMinimum(uint256 attempted, uint256 required);
error LoanBelowMinimum(uint256 attempted, uint256 required);
error InvalidMinimumThreshold(string reason);

// Rolling credit expansion
error DelinquentBorrower(address user, uint256 missedPayments);
error ExpansionBelowMinimum(uint256 amount, uint256 minimum);
error InsufficientCollateral(uint256 newPrincipal, uint256 maxBorrowable);
error InsufficientPoolLiquidity(uint256 requested, uint256 available);
error NoActiveRollingLoan(address user);

// Fee configuration
error ActionFeeBoundsViolation(uint128 amount, uint128 min, uint128 max);
error UnauthorizedFeeConfiguration();
error PoolNotInitialized(uint256 pid);
error IndexNotFound(uint256 indexId);
error ActionFeeDisabled(uint256 pid, bytes32 action);
error IndexActionFeeDisabled(uint256 indexId, bytes32 action);
error AumFeeOutOfBounds(uint16 attempted, uint16 min, uint16 max);

// Pool initialization and configuration
error PoolAlreadyExists(uint256 pid);
error PermissionlessPoolAlreadyInitialized(address underlying, uint256 existingPid);
error DefaultPoolConfigNotSet();
error InvalidUnderlying();
error InvalidParameterRange(string parameter);
error InvalidAumFeeBounds();
error InsufficientPoolCreationFee(uint256 required, uint256 provided);
error InsufficientManagedPoolCreationFee(uint256 required, uint256 provided);
error InsufficientIndexCreationFee(uint256 required, uint256 provided);
error ParameterIsImmutable(string parameter);
error PoolDoesNotExist(uint256 pid);
error PoolNotManaged(uint256 pid);
error InvalidManagedPoolConfig(string reason);
error UnauthorizedAdmin();
error InvalidDepositCap();
error InvalidLTVRatio();
error InvalidCollateralizationRatio();
error InvalidMaintenanceRate();
error InvalidFlashLoanFee();
error InvalidAPYRate(string parameter);
error InvalidFixedTermDuration();
error InvalidFixedTermFee();
error ManagedPoolCreationDisabled();
error InvalidTreasuryAddress();
error NotPoolManager(address caller, address manager);
error OnlyManagerAllowed();
error InvalidManagerTransfer();
error ManagerAlreadyRenounced();
error WhitelistRequired(bytes32 positionKey, uint256 poolId);
error TreasuryNotSet();
error PoolCreationFeeTransferFailed();
error IndexCreationFeeTransferFailed();
error DepositCapExceeded(uint256 attempted, uint256 cap);
error MaxUserCountExceeded(uint256 maxUsers);

// EqualIndex validation
error InvalidArrayLength();
error InvalidBundleDefinition();
error InvalidFeeReceiver();
error InvalidUnits();
error InsufficientBalance();
error NotImplemented();
error IndexPaused(uint256 indexId);
error UnknownIndex(uint256 indexId);
error CapExceeded(uint256 indexId, uint256 requested, uint256 cap);
error Unauthorized();
error Reentrancy();
error FlashLoanUnderpaid(uint256 indexId, address asset, uint256 expected, uint256 received);
error NoSurplus();
error UnknownAsset();
error NoYieldAvailable();
error NoPoolForAsset(address asset);
error EncumbranceUnderflow(uint256 requested, uint256 available);
error InsufficientUnencumberedPrincipal(uint256 requested, uint256 available);
error NotMemberOfRequiredPool(bytes32 positionKey, uint256 poolId);
error InsufficientIndexTokens(uint256 requested, uint256 available);

// Index token controls
error NotMinter();
error InvalidMinter();

// Position NFT errors
error NotNFTOwner(address caller, uint256 tokenId);
error InvalidTokenId(uint256 tokenId);
error SolvencyViolation(uint256 principal, uint256 debt, uint256 ltvBps);
error InsufficientPrincipal(uint256 requested, uint256 available);
error ActiveLoansExist();
// Pool membership validation
error PoolMembershipRequired(bytes32 positionKey, uint256 poolId);
error MembershipAlreadyExists(bytes32 positionKey, uint256 poolId);
error CannotClearMembership(bytes32 positionKey, uint256 poolId, string reason);

// Accounting and fee base validation
error NegativeFeeBase();
error InvalidAssetComparison();
error FeeBaseOverflow();
error DebtUnderflow();
error SameAssetDebtMismatch(uint256 expected, uint256 actual);
error CrossAssetDebtLeakage(uint256 crossAssetDebt);
error NativeTransferFailed(address to, uint256 amount);
error UnexpectedMsgValue(uint256 value);

// Direct lending errors
error DirectError_InvalidPositionNFT();
error DirectError_InvalidTimestamp();
error DirectError_ZeroAmount();
error DirectError_InvalidAsset();
error DirectError_InvalidOffer();
error DirectError_InvalidConfiguration();
error DirectError_InvalidRatio();
error DirectError_InvalidFillAmount();
error DirectError_InvalidAgreementState();
error DirectError_AutoExerciseNotAllowed();
error DirectError_EarlyExerciseNotAllowed();
error DirectError_EarlyRepayNotAllowed();
error DirectError_LenderCallNotAllowed();
error DirectError_GracePeriodActive();
error DirectError_GracePeriodExpired();
error DirectError_InvalidTrancheAmount();
error DirectError_NotOfferPoster();
error DirectError_TrancheInsufficient();
error DirectError_CancellationReason();

// Rolling lending errors
error RollingError_InvalidInterval(uint32 provided, uint32 minIntervalSeconds);
error RollingError_InvalidPaymentCount(uint16 provided, uint16 maxPaymentCount);
error RollingError_InvalidGracePeriod(uint32 provided, uint32 paymentIntervalSeconds);
error RollingError_InvalidAPY(uint16 provided, uint16 minRollingApyBps, uint16 maxRollingApyBps);
error RollingError_ExcessivePremium(uint256 provided, uint256 maxPremium);
error RollingError_MinPayment(uint256 amount, uint256 minimum);
error RollingError_AmortizationDisabled();
error RollingError_RecoveryNotEligible();
error RollingError_DustPayment(uint256 amount, uint256 minPayment);

// Limit order errors

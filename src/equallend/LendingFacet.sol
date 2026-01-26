// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibActionFees} from "../libraries/LibActionFees.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibNetEquity} from "../libraries/LibNetEquity.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibLoanManager} from "../libraries/LibLoanManager.sol";
import {LibLoanHelpers} from "../libraries/LibLoanHelpers.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {
    NotNFTOwner,
    PoolNotInitialized,
    InsufficientPrincipal,
    SolvencyViolation,
    LoanBelowMinimum,
    RollingError_MinPayment
} from "../libraries/Errors.sol";

/// @title LendingFacet
/// @notice Handles rolling and fixed-term lending operations for Position NFTs
contract LendingFacet is ReentrancyGuardModifiers {
    /// @notice Emitted when a rolling loan is opened from a Position NFT
    event RollingLoanOpenedFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 principal,
        bool depositBacked
    );

    /// @notice Emitted when a payment is made on a rolling loan from a Position NFT
    event PaymentMadeFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 paymentAmount,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 remainingPrincipal
    );

    /// @notice Emitted when a rolling loan is expanded from a Position NFT
    event RollingLoanExpandedFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 expandedAmount,
        uint256 newPrincipalRemaining
    );

    /// @notice Emitted when a rolling loan is closed from a Position NFT
    event RollingLoanClosedFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 collateralReleased
    );

    /// @notice Emitted when a fixed-term loan is opened from a Position NFT
    event FixedLoanOpenedFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 loanId,
        uint256 principal,
        uint256 fullInterest,
        uint40 expiry,
        uint16 apyBps,
        bool interestRealizedAtInitiation
    );

    /// @notice Emitted when a fixed-term loan is repaid from a Position NFT
    event FixedLoanRepaidFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 loanId,
        uint256 principalPaid,
        uint256 remainingPrincipal
    );

    event AutoYieldRolledForBorrow(
        uint256 indexed tokenId,
        uint256 indexed poolId,
        bytes32 indexed positionKey,
        uint256 amount
    );

    /// @notice Get the app storage
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    /// @notice Get a pool by ID with validation
    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibPositionHelpers.pool(pid);
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
        return p;
    }

    /// @notice Require that the caller owns the specified NFT
    function _requireOwnership(uint256 tokenId) internal view {
        LibPositionHelpers.requireOwnership(tokenId);
    }

    /// @notice Get the position key for a token ID
    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    function _autoRollYieldForBorrow(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid,
        uint256 tokenId
    ) internal {
        uint256 accruedYield = p.userAccruedYield[positionKey];
        if (accruedYield == 0 || p.yieldReserve < accruedYield) {
            return;
        }
        // Convert accrued yield into principal so backing is available for fee routing.
        p.userPrincipal[positionKey] += accruedYield;
        p.userAccruedYield[positionKey] = 0;
        p.yieldReserve -= accruedYield;
        p.trackedBalance += accruedYield;
        if (LibCurrency.isNative(p.underlying)) {
            LibAppStorage.s().nativeTrackedTotal += accruedYield;
        }
        p.totalDeposits += accruedYield;
        emit AutoYieldRolledForBorrow(tokenId, pid, positionKey, accruedYield);
    }

    function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) internal returns (bool) {
        return LibPositionHelpers.ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }

    function _checkSolvency(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 newPrincipal,
        uint256 newDebt
    ) internal view returns (bool isSolvent) {
        return LibSolvencyChecks.checkSolvency(p, positionKey, newPrincipal, newDebt);
    }

    function _calculateTotalDebt(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 totalDebt) {
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function _calculateMissedEpochs(Types.RollingCreditLoan storage loan) internal view returns (uint256) {
        return LibLoanHelpers.calculateMissedEpochs(loan);
    }

    function _delinquencyThresholds() internal view returns (uint8 delinquentEpochs, uint8 penaltyEpochs) {
        return LibLoanHelpers.delinquencyThresholds();
    }

    function _syncMissedPayments(Types.RollingCreditLoan storage loan) internal {
        LibLoanHelpers.syncMissedPayments(loan);
    }

    function _calculateAccruedInterest(uint256 principal, uint16 apyBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return LibLoanHelpers.calculateAccruedInterest(principal, apyBps, elapsed);
    }

    function _addLoanIdWithIndex(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId
    ) internal {
        LibLoanHelpers.addLoanIdWithIndex(p, pid, positionKey, loanId);
    }

    function _removeLoanIdByIndex(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 loanIndex
    ) internal {
        LibLoanHelpers.removeLoanIdByIndex(p, pid, positionKey, loanId, loanIndex);
    }

    /// @notice Open a rolling credit loan from a Position NFT
    /// @param tokenId The token ID
    /// @param amount The loan amount to borrow
    function openRollingFromPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 amount
    ) public payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        require(amount > 0, "PositionNFT: amount=0");

        // Enforce minimum loan amount threshold
        if (amount < p.poolConfig.minLoanAmount) {
            revert LoanBelowMinimum(amount, p.poolConfig.minLoanAmount);
        }

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        require(loan.principalRemaining == 0, "PositionNFT: loan exists");

        // Settle fees before collateral checks
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);
        _autoRollYieldForBorrow(p, positionKey, pid, tokenId);

        // Collateral checks - only deposit-backed loans supported
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        uint256 principalBalance = p.userPrincipal[positionKey];
        require(principalBalance >= encumbered, "PositionNFT: locked exceeds principal");
        uint256 collateralValue = principalBalance - encumbered;
        require(collateralValue > 0, "PositionNFT: no principal");
        // Calculate existing debt using deterministic on-chain data
        uint256 existingBorrowed = _calculateTotalDebt(p, positionKey, pid);
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, positionKey, p.underlying);
        collateralValue = LibNetEquity.calculateNetEquity(collateralValue, sameAssetDebt);
        require(collateralValue > 0, "PositionNFT: no net equity");

        uint256 principalAtOpen = principalBalance;

        // Verify solvency after new loan using only immutable pool config
        uint256 newDebt = existingBorrowed + amount;
        require(_checkSolvency(p, positionKey, collateralValue, newDebt), "PositionNFT: LTV exceeded");

        // Charge ACTION_BORROW fee from position principal
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_BORROW, positionKey);

        // Enforce per-pool liquidity
        require(amount <= p.trackedBalance, "PositionNFT: insufficient pool liquidity");

        // Transfer borrowed funds to NFT owner
        p.trackedBalance -= amount;
        if (LibCurrency.isNative(p.underlying) && amount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }
        LibCurrency.transfer(p.underlying, msg.sender, amount);

        // Create loan in rollingLoans[positionKey]
        loan.principal = amount;
        loan.principalRemaining = amount;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.apyBps = 0;
        loan.missedPayments = 0;
        loan.paymentIntervalSecs = 30 days;
        loan.depositBacked = true;
        loan.active = true;
        loan.principalAtOpen = principalAtOpen;

        _increaseActiveCreditDebt(p, pid, positionKey, amount);

        emit RollingLoanOpenedFromPosition(tokenId, msg.sender, pid, amount, true);
    }

    /// @notice Make a payment on a rolling credit loan from a Position NFT
    /// @param tokenId The token ID
    /// @param paymentAmount The payment amount (interest + principal)
    function makePaymentFromPosition(uint256 tokenId, uint256 pid, uint256 paymentAmount) public payable nonReentrant {
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        require(loan.active, "PositionNFT: no active loan");
        require(loan.principalRemaining > 0, "PositionNFT: no principal remaining");
        require(paymentAmount > 0, "PositionNFT: amount=0");
        LibCurrency.assertMsgValue(p.underlying, paymentAmount);

        // Track missed epochs before computing amounts
        _syncMissedPayments(loan);
        uint16 minPaymentBps = LibAppStorage.s().rollingMinPaymentBps;
        if (minPaymentBps > 0) {
            uint256 minPayment = Math.mulDiv(loan.principalRemaining, minPaymentBps, 10_000);
            if (mulmod(loan.principalRemaining, minPaymentBps, 10_000) != 0) {
                minPayment += 1;
            }
            if (paymentAmount < minPayment) {
                revert RollingError_MinPayment(paymentAmount, minPayment);
            }
        }

        // Settle yield for borrower (as depositor) before modifying balances
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);

        // Transfer payment from NFT owner to pool (handle fee-on-transfer tokens)
        uint256 received = LibCurrency.pull(p.underlying, msg.sender, paymentAmount);
        p.trackedBalance += received;

        // Charge ACTION_REPAY fee
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_REPAY, positionKey);

        // Entire payment reduces principal when interest is disabled
        uint256 interestPortion = 0;
        uint256 principalPortion = received;

        // Cap principal portion to remaining principal
        if (principalPortion > loan.principalRemaining) {
            principalPortion = loan.principalRemaining;
        }

        // Update loan state in rollingLoans[positionKey]
        loan.principalRemaining -= principalPortion;
        _decreaseActiveCreditDebt(p, pid, positionKey, principalPortion);

        // Reset payment tracking
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.missedPayments = 0;

        // If fully repaid, set loan as inactive
        if (loan.principalRemaining == 0) {
            loan.active = false;
        }

        emit PaymentMadeFromPosition(
            tokenId,
            msg.sender,
            pid,
            received,
            principalPortion,
            interestPortion,
            loan.principalRemaining
        );
    }

    /// @notice Expand an existing rolling credit loan from a Position NFT
    /// @param tokenId The token ID
    /// @param amount The additional amount to borrow
    function expandRollingFromPosition(uint256 tokenId, uint256 pid, uint256 amount) public payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        require(amount > 0, "PositionNFT: amount=0");

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        require(loan.active, "PositionNFT: no active loan");
        require(loan.principalRemaining > 0, "PositionNFT: loan fully repaid");

        // Enforce minimum topup amount threshold
        if (amount < p.poolConfig.minTopupAmount) {
            revert LoanBelowMinimum(amount, p.poolConfig.minTopupAmount);
        }

        // Settle fees before collateral checks
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);
        _autoRollYieldForBorrow(p, positionKey, pid, tokenId);

        // Disallow new draws while delinquent
        _syncMissedPayments(loan);
        (uint8 delinquentEpochs,) = _delinquencyThresholds();
        require(loan.missedPayments < delinquentEpochs, "PositionNFT: loan delinquent");

        // Verify solvency after expansion using deterministic on-chain data
        // Only deposit-backed loans are supported
        require(loan.depositBacked, "PositionNFT: only deposit-backed loans supported");
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        uint256 principalBalance = p.userPrincipal[positionKey];
        require(principalBalance >= encumbered, "PositionNFT: locked exceeds principal");
        uint256 collateralValue = principalBalance - encumbered;
        require(collateralValue > 0, "PositionNFT: no principal");

        // Calculate existing debt using deterministic on-chain data
        uint256 existingBorrowed = _calculateTotalDebt(p, positionKey, pid);
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, positionKey, p.underlying);
        collateralValue = LibNetEquity.calculateNetEquity(collateralValue, sameAssetDebt);
        require(collateralValue > 0, "PositionNFT: no net equity");

        // Verify solvency after expansion using only immutable pool config
        uint256 newDebt = existingBorrowed + amount;
        require(_checkSolvency(p, positionKey, collateralValue, newDebt), "PositionNFT: LTV exceeded");

        // Charge ACTION_BORROW fee from position principal
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_BORROW, positionKey);

        // Enforce per-pool liquidity
        require(amount <= p.trackedBalance, "PositionNFT: insufficient pool liquidity");

        // Transfer borrowed funds to NFT owner
        p.trackedBalance -= amount;
        if (LibCurrency.isNative(p.underlying) && amount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }
        LibCurrency.transfer(p.underlying, msg.sender, amount);

        // Update loan state - increase both principal and principalRemaining
        loan.principal += amount;
        loan.principalRemaining += amount;
        _increaseActiveCreditDebt(p, pid, positionKey, amount);

        emit RollingLoanExpandedFromPosition(tokenId, msg.sender, pid, amount, loan.principalRemaining);
    }

    /// @notice Close a rolling credit loan from a Position NFT, repaying accrued interest and principal
    /// @param tokenId The token ID
    function closeRollingCreditFromPosition(uint256 tokenId, uint256 pid) public payable nonReentrant {
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];

        // Verify loan is active
        require(loan.active, "PositionNFT: loan not active");

        // Settle any depositor yield before manipulating balances
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);

        uint256 principalRemaining = loan.principalRemaining;
        uint256 totalPayoff = principalRemaining;
        LibCurrency.assertMsgValue(p.underlying, totalPayoff);

        if (totalPayoff > 0) {
            // Transfer payoff from NFT owner to pool (handle fee-on-transfer tokens)
            uint256 received = LibCurrency.pull(p.underlying, msg.sender, totalPayoff);
            require(received >= totalPayoff, "PositionNFT: payoff underfunded");
            p.trackedBalance += received;

            // Reduce principal remaining to zero
            loan.principalRemaining = 0;
        }

        // Charge ACTION_CLOSE_ROLLING fee
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_CLOSE_ROLLING, positionKey);

        _decreaseActiveCreditDebt(p, pid, positionKey, principalRemaining);

        // Clear loan state in rollingLoans[positionKey]
        loan.active = false;
        loan.principal = 0;
        loan.openedAt = 0;
        loan.lastPaymentTimestamp = 0;
        loan.lastAccrualTs = 0;
        loan.apyBps = 0;
        loan.missedPayments = 0;
        loan.paymentIntervalSecs = 0;
        loan.depositBacked = false;

        emit RollingLoanClosedFromPosition(tokenId, msg.sender, pid, 0);
    }

    /// @notice Open a fixed-term loan from a Position NFT
    /// @param tokenId The token ID
    /// @param amount The loan amount to borrow
    /// @param termIndex The index of the fixed-term configuration to use
    /// @return loanId The ID of the newly created loan
    function openFixedFromPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 amount,
        uint256 termIndex
    ) public payable nonReentrant returns (uint256 loanId) {
        LibCurrency.assertZeroMsgValue();
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        require(amount > 0, "PositionNFT: amount=0");

        // Enforce minimum loan amount threshold
        if (amount < p.poolConfig.minLoanAmount) {
            revert LoanBelowMinimum(amount, p.poolConfig.minLoanAmount);
        }

        // Get fixed-term configuration
        require(termIndex < p.poolConfig.fixedTermConfigs.length, "PositionNFT: bad term");
        Types.FixedTermConfig storage cfg = p.poolConfig.fixedTermConfigs[termIndex];
        require(cfg.durationSecs > 0, "PositionNFT: duration=0");

        // Settle fees before collateral checks
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);
        _autoRollYieldForBorrow(p, positionKey, pid, tokenId);

        // Calculate total fees (interest disabled for self-secured fixed-term loans)
        uint256 fullInterest = 0;
        uint256 actionFee = LibActionFees.preview(p, pid, LibActionFees.ACTION_BORROW);
        uint256 totalFees = actionFee;

        // Verify solvency with existing loans using deterministic on-chain data
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        uint256 principalBalance = p.userPrincipal[positionKey];
        require(principalBalance >= encumbered, "PositionNFT: locked exceeds principal");
        uint256 collateralValue = principalBalance - encumbered;
        if (totalFees > 0) {
            require(collateralValue >= totalFees, "PositionNFT: fees>principal");
            collateralValue -= totalFees;
        }
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, positionKey, p.underlying);
        collateralValue = LibNetEquity.calculateNetEquity(collateralValue, sameAssetDebt);
        require(collateralValue > 0, "PositionNFT: no net equity");

        // Calculate existing debt using deterministic on-chain data
        uint256 existingBorrowed = _calculateTotalDebt(p, positionKey, pid);

        // Verify solvency after new loan using only immutable pool config (no oracles)
        uint256 newDebt = existingBorrowed + amount;
        require(_checkSolvency(p, positionKey, collateralValue, newDebt), "PositionNFT: LTV exceeded");

        uint256 principalAtOpen = principalBalance;

        // No principal deduction for interest when interest is disabled

        // Charge ACTION_BORROW fee from position principal
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_BORROW, positionKey);

        // No interest routing for fixed-term self-secured loans

        // Enforce per-pool liquidity
        require(amount <= p.trackedBalance, "PositionNFT: insufficient pool liquidity");

        // Transfer borrowed funds to NFT owner
        p.trackedBalance -= amount;
        if (LibCurrency.isNative(p.underlying) && amount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }
        LibCurrency.transfer(p.underlying, msg.sender, amount);

        // Create loan in fixedTermLoans[loanId] with borrower = positionKey
        loanId = ++p.nextFixedLoanId;
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = amount;
        loan.principalRemaining = amount;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = uint40(block.timestamp + cfg.durationSecs);
        loan.apyBps = cfg.apyBps;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = false;
        loan.principalAtOpen = principalAtOpen;

        // Add loanId to userFixedLoanIds[positionKey] and index mapping
        p.activeFixedLoanCount[positionKey] += 1;
        p.fixedTermPrincipalRemaining[positionKey] += amount;
        _addLoanIdWithIndex(p, pid, positionKey, loanId);

        _increaseActiveCreditDebt(p, pid, positionKey, amount);

        emit FixedLoanOpenedFromPosition(
            tokenId, msg.sender, pid, loanId, amount, 0, loan.expiry, cfg.apyBps, false
        );
    }

    /// @notice Repay a fixed-term loan from a Position NFT
    /// @param tokenId The token ID
    /// @param loanId The loan ID to repay
    /// @param amount The repayment amount
    function repayFixedFromPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 loanId,
        uint256 amount
    ) public payable nonReentrant {
        // Verify NFT ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        require(!loan.closed, "PositionNFT: loan closed");

        // Verify loan belongs to position
        require(loan.borrower == positionKey, "PositionNFT: not borrower");
        require(amount > 0, "PositionNFT: amount=0");
        LibCurrency.assertMsgValue(p.underlying, amount);

        // Settle fees before repayment
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);

        uint256 principalPaid = amount;
        if (principalPaid > loan.principalRemaining) {
            principalPaid = loan.principalRemaining;
        }

        // Transfer payment from NFT owner to pool
        uint256 received = LibCurrency.pull(p.underlying, msg.sender, principalPaid);
        require(received >= principalPaid, "PositionNFT: repay underfunded");
        p.trackedBalance += received;

        // Charge ACTION_REPAY fee
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_REPAY, positionKey);

        // Update loan state in fixedTermLoans[loanId]
        loan.principalRemaining -= principalPaid;
        uint256 cached = p.fixedTermPrincipalRemaining[positionKey];
        p.fixedTermPrincipalRemaining[positionKey] = cached >= principalPaid ? cached - principalPaid : 0;
        _decreaseActiveCreditDebt(p, pid, positionKey, principalPaid);

        if (loan.principalRemaining == 0) {
            loan.closed = true;
            p.activeFixedLoanCount[positionKey] -= 1;
            uint256 loanIndex = p.loanIdToIndex[positionKey][loanId];
            _removeLoanIdByIndex(p, pid, positionKey, loanId, loanIndex);
        }

        emit FixedLoanRepaidFromPosition(
            tokenId,
            msg.sender,
            pid,
            loanId,
            principalPaid,
            loan.principalRemaining
        );
    }

    function _increaseActiveCreditDebt(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        p.activeCreditPrincipalTotal += amount;
        Types.ActiveCreditState storage debtState = p.userActiveCreditStateDebt[positionKey];
        LibActiveCreditIndex.applyWeightedIncreaseWithGate(p, debtState, amount, pid, positionKey, true);
        debtState.indexSnapshot = p.activeCreditIndex;
    }

    function _decreaseActiveCreditDebt(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        Types.ActiveCreditState storage debtState = p.userActiveCreditStateDebt[positionKey];
        uint256 principalBefore = debtState.principal;
        uint256 decrease = principalBefore >= amount ? amount : principalBefore;
        if (p.activeCreditPrincipalTotal >= decrease) {
            p.activeCreditPrincipalTotal -= decrease;
        } else {
            p.activeCreditPrincipalTotal = 0;
        }
        LibActiveCreditIndex.applyPrincipalDecrease(p, debtState, decrease);
        if (principalBefore <= amount || debtState.principal == 0) {
            LibActiveCreditIndex.resetIfZeroWithGate(debtState, pid, positionKey, true);
        } else {
            debtState.indexSnapshot = p.activeCreditIndex;
        }
    }

}

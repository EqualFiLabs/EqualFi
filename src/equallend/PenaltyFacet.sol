// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibLoanHelpers} from "../libraries/LibLoanHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {PoolNotInitialized, InsufficientPrincipal} from "../libraries/Errors.sol";

/// @title PenaltyFacet
/// @notice Handles penalty settlement of rolling and fixed-term loans for Position NFTs
contract PenaltyFacet is ReentrancyGuardModifiers {
    /// @notice Emitted when a Position NFT is penalized and collateral is seized
    event PositionPenalized(
        uint256 indexed tokenId,
        address indexed enforcer,
        uint256 indexed poolId,
        uint256 collateralSeized,
        uint256 enforcerShare,
        uint256 protocolShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare,
        bool isRolling
    );

    /// @notice Emitted when a fixed-term loan is defaulted with a penalty
    event TermLoanDefaulted(
        uint256 indexed tokenId,
        address indexed enforcer,
        uint256 indexed poolId,
        uint256 loanId,
        uint256 penaltyApplied,
        uint256 principalAtOpen
    );

    /// @notice Emitted when a rolling loan is penalized after delinquency
    event RollingLoanPenalized(
        uint256 indexed tokenId,
        address indexed enforcer,
        uint256 indexed poolId,
        uint256 enforcerShare,
        uint256 protocolShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare,
        uint256 penaltyApplied,
        uint256 principalAtOpen
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

    /// @notice Get the position key for a token ID
    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) internal returns (bool) {
        return LibPositionHelpers.ensurePoolMembership(positionKey, pid, allowAutoJoin);
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

    function _removeLoanIdByIndex(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 loanIndex
    ) internal {
        LibLoanHelpers.removeLoanIdByIndex(p, pid, positionKey, loanId, loanIndex);
    }

    function penalizePositionRolling(uint256 tokenId, uint256 pid, address enforcer) public nonReentrant {
        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];

        // Verify loan is delinquent (3+ missed payments)
        require(loan.active, "PositionNFT: loan not active");
        require(loan.principalRemaining > 0, "PositionNFT: no principal");
        _syncMissedPayments(loan);
        (, uint8 penaltyEpochs) = _delinquencyThresholds();
        require(loan.missedPayments >= penaltyEpochs, "PositionNFT: not delinquent");

        LibActiveCreditIndex.settle(pid, positionKey);

        // Get collateral from userPrincipal[positionKey] (only deposit-backed loans supported)
        require(loan.depositBacked, "PositionNFT: only deposit-backed loans supported");
        uint256 principalBalance = p.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (encumbered >= principalBalance) {
            revert InsufficientPrincipal(encumbered, principalBalance);
        }
        uint256 availableCollateral = principalBalance - encumbered;

        uint256 penalty = LibLoanHelpers.calculatePenalty(loan.principalAtOpen);
        uint256 principalRemainingBefore = loan.principalRemaining;
        uint256 penaltyApplied = penalty < principalRemainingBefore ? penalty : principalRemainingBefore;

        uint256 totalSeized = principalRemainingBefore + penaltyApplied;
        require(availableCollateral >= totalSeized, "PositionNFT: insufficient collateral for penalty");
        uint256 available = p.trackedBalance;
        require(available >= penaltyApplied, "PositionNFT: insufficient pool liquidity");
        require(
            LibCurrency.balanceOfSelf(p.underlying) >= penaltyApplied,
            "PositionNFT: insufficient contract balance"
        );
        // Calculate distribution: 10% enforcer, remaining split 70/10/20 feeIndex/protocol/activeCredit
        uint256 enforcerShare = penaltyApplied / 10; // 10%
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        (uint256 protocolShare, uint256 activeCreditShare, uint256 feeIndexShare) =
            LibFeeRouter.previewSplit(protocolAmount);

        // Apply penalty and distribute
        p.userPrincipal[positionKey] = principalBalance - totalSeized;
        if (p.totalDeposits >= totalSeized) {
            p.totalDeposits -= totalSeized;
        }
        p.trackedBalance = available - enforcerShare;
        if (LibCurrency.isNative(p.underlying) && enforcerShare > 0) {
            LibAppStorage.s().nativeTrackedTotal -= enforcerShare;
        }

        // Distribute enforcer share
        if (enforcerShare > 0) {
            LibCurrency.transfer(p.underlying, enforcer, enforcerShare);
        }

        if (protocolAmount > 0) {
            LibFeeRouter.routeSamePool(pid, protocolAmount, bytes32("penalty"), true, 0);
        }

        if (principalRemainingBefore > 0) {
            Types.ActiveCreditState storage debtState = p.userActiveCreditStateDebt[positionKey];
            uint256 principalBefore = debtState.principal;
            uint256 decrease = principalBefore >= principalRemainingBefore
                ? principalRemainingBefore
                : principalBefore;
            if (p.activeCreditPrincipalTotal >= decrease) {
                p.activeCreditPrincipalTotal -= decrease;
            } else {
                p.activeCreditPrincipalTotal = 0;
            }
            LibActiveCreditIndex.applyPrincipalDecrease(p, debtState, decrease);
            if (principalBefore <= principalRemainingBefore || debtState.principal == 0) {
                LibActiveCreditIndex.resetIfZeroWithGate(debtState, pid, positionKey, true);
            } else {
                debtState.indexSnapshot = p.activeCreditIndex;
            }
        }

        // Clear rolling debt after seizure
        loan.principalRemaining = 0;
        loan.active = false;

        emit RollingLoanPenalized(
            tokenId,
            enforcer,
            pid,
            enforcerShare,
            protocolShare,
            feeIndexShare,
            activeCreditShare,
            penaltyApplied,
            loan.principalAtOpen
        );
    }

    /// @notice Penalize a fixed-term loan from a Position NFT
    /// @param tokenId The token ID
    /// @param loanId The loan ID to penalize
    /// @param enforcer The address receiving the enforcement bounty
    function penalizePositionFixed(uint256 tokenId, uint256 pid, uint256 loanId, address enforcer)
        public
        nonReentrant
    {
        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, false);

        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];

        // Verify loan belongs to position
        require(loan.borrower == positionKey, "PositionNFT: not borrower");
        require(!loan.closed, "PositionNFT: loan closed");

        // Verify loan is expired
        require(block.timestamp >= loan.expiry, "PositionNFT: not expired");

        LibActiveCreditIndex.settle(pid, positionKey);

        uint256 penalty = LibLoanHelpers.calculatePenalty(loan.principalAtOpen);
        uint256 principalRemainingBefore = loan.principalRemaining;
        uint256 penaltyApplied = penalty < principalRemainingBefore ? penalty : principalRemainingBefore;
        uint256 totalSeized = principalRemainingBefore + penaltyApplied;

        // Get collateral from userPrincipal[positionKey]
        uint256 principalBalance = p.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (encumbered >= principalBalance) {
            revert InsufficientPrincipal(encumbered, principalBalance);
        }
        uint256 availableCollateral = principalBalance - encumbered;
        require(availableCollateral >= totalSeized, "PositionNFT: insufficient collateral for penalty");
        uint256 available = p.trackedBalance;
        require(available >= penaltyApplied, "PositionNFT: insufficient pool liquidity");
        require(
            LibCurrency.balanceOfSelf(p.underlying) >= penaltyApplied,
            "PositionNFT: insufficient contract balance"
        );

        // Calculate distribution: 10% enforcer, remaining split 70/10/20 feeIndex/protocol/activeCredit
        uint256 enforcerShare = penaltyApplied / 10; // 10%
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        (uint256 protocolShare, uint256 activeCreditShare, uint256 feeIndexShare) =
            LibFeeRouter.previewSplit(protocolAmount);

        // Apply penalty and distribute
        p.userPrincipal[positionKey] = principalBalance - totalSeized;
        if (p.totalDeposits >= totalSeized) {
            p.totalDeposits -= totalSeized;
        }
        p.trackedBalance = available - enforcerShare;
        if (LibCurrency.isNative(p.underlying) && enforcerShare > 0) {
            LibAppStorage.s().nativeTrackedTotal -= enforcerShare;
        }

        // Distribute enforcer share
        if (enforcerShare > 0) {
            LibCurrency.transfer(p.underlying, enforcer, enforcerShare);
        }

        if (protocolAmount > 0) {
            LibFeeRouter.routeSamePool(pid, protocolAmount, bytes32("penalty"), true, 0);
        }

        if (principalRemainingBefore > 0) {
            Types.ActiveCreditState storage debtState = p.userActiveCreditStateDebt[positionKey];
            uint256 principalBefore = debtState.principal;
            uint256 decrease = principalBefore >= principalRemainingBefore
                ? principalRemainingBefore
                : principalBefore;
            if (p.activeCreditPrincipalTotal >= decrease) {
                p.activeCreditPrincipalTotal -= decrease;
            } else {
                p.activeCreditPrincipalTotal = 0;
            }
            LibActiveCreditIndex.applyPrincipalDecrease(p, debtState, decrease);
            if (principalBefore <= principalRemainingBefore || debtState.principal == 0) {
                LibActiveCreditIndex.resetIfZeroWithGate(debtState, pid, positionKey, true);
            } else {
                debtState.indexSnapshot = p.activeCreditIndex;
            }
        }

        // Close loan in fixedTermLoans[loanId]; penalty reduces remaining principal
        loan.principalRemaining = 0;
        loan.closed = true;

        // Update active loan count
        if (p.activeFixedLoanCount[positionKey] > 0) {
            p.activeFixedLoanCount[positionKey] -= 1;
        }
        if (p.fixedTermPrincipalRemaining[positionKey] > 0) {
            uint256 cached = p.fixedTermPrincipalRemaining[positionKey];
            p.fixedTermPrincipalRemaining[positionKey] =
                cached >= principalRemainingBefore ? cached - principalRemainingBefore : 0;
        }

        // Remove loanId from userFixedLoanIds[positionKey] using index mapping
        uint256 loanIndex = p.loanIdToIndex[positionKey][loanId];
        _removeLoanIdByIndex(p, pid, positionKey, loanId, loanIndex);

        emit TermLoanDefaulted(tokenId, enforcer, pid, loanId, penaltyApplied, loan.principalAtOpen);
    }
}

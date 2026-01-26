// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibLoanHelpers} from "../libraries/LibLoanHelpers.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @title PositionViewFacet
/// @notice Read-only views for Position NFTs across pools and loan types
contract PositionViewFacet {
    /// @notice Get app storage
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    /// @notice Get a pool by ID (no initialization guard to preserve legacy behavior)
    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        return LibPositionHelpers.pool(pid);
    }

    /// @notice Get the position key for a token ID
    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    function _calculateTotalDebt(Types.PoolData storage p, bytes32 positionKey, uint256 pid)
        internal
        view
        returns (uint256)
    {
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function _calculateMissedEpochsView(Types.RollingCreditLoan memory loan) internal view returns (uint256) {
        return LibLoanHelpers.calculateMissedEpochsView(loan);
    }

    function _calculateMissedEpochs(Types.RollingCreditLoan storage loan) internal view returns (uint256) {
        return LibLoanHelpers.calculateMissedEpochs(loan);
    }

    function _delinquencyThresholds() internal view returns (uint8 delinquentEpochs, uint8 penaltyEpochs) {
        return LibLoanHelpers.delinquencyThresholds();
    }

    /// @notice Get the complete state of a Position NFT
    function getPositionState(uint256 tokenId, uint256 pid) public view returns (Types.PositionState memory state) {
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);

        state.tokenId = tokenId;
        state.poolId = pid;
        state.underlying = p.underlying;
        state.principal = p.userPrincipal[positionKey];
        state.accruedYield = LibFeeIndex.pendingYield(pid, positionKey);
        state.feeIndexCheckpoint = p.userFeeIndex[positionKey];
        state.maintenanceIndexCheckpoint = p.userMaintenanceIndex[positionKey];
        state.externalCollateral = 0;

        state.rollingLoan = p.rollingLoans[positionKey];
        state.fixedLoanIds = p.userFixedLoanIds[positionKey];

        uint256 missedEpochs = _calculateMissedEpochsView(state.rollingLoan);
        if (missedEpochs > 3) {
            missedEpochs = 3;
        }
        if (missedEpochs > state.rollingLoan.missedPayments) {
            state.rollingLoan.missedPayments = uint8(missedEpochs);
        }

        state.totalDebt = _calculateTotalDebt(p, positionKey, pid);
        state.solvencyRatio = state.totalDebt > 0 ? (state.principal * 10_000) / state.totalDebt : type(uint256).max;

        (state.isDelinquent, state.eligibleForPenalty) =
            _computeDelinquencyFlags(p, positionKey, state.rollingLoan, state.fixedLoanIds);
    }

    /// @notice Get the solvency information for a Position NFT
    function getPositionSolvency(uint256 tokenId, uint256 pid)
        public
        view
        returns (uint256 principal, uint256 debt, uint256 ratio)
    {
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);

        principal = p.userPrincipal[positionKey];
        debt = _calculateTotalDebt(p, positionKey, pid);
        ratio = debt > 0 ? (principal * 10_000) / debt : type(uint256).max;
    }

    /// @notice Get a summarized view of all loans for a Position NFT
    function getPositionLoanSummary(uint256 tokenId, uint256 pid)
        public
        view
        returns (uint256 totalLoans, uint256 activeLoans, uint256 totalDebt, uint256 nextExpiryTimestamp, bool hasDelinquentLoans)
    {
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        uint256 nowTs = block.timestamp;

        Types.RollingCreditLoan storage rollingLoan = p.rollingLoans[positionKey];
        if (rollingLoan.active) {
            totalDebt += rollingLoan.principalRemaining;

            (uint8 delinquentEpochs,) = _delinquencyThresholds();
            uint256 missedEpochs = _calculateMissedEpochs(rollingLoan);
            if (missedEpochs > 3) missedEpochs = 3;
            uint256 effectiveMissed = missedEpochs > rollingLoan.missedPayments ? missedEpochs : rollingLoan.missedPayments;
            if (effectiveMissed >= delinquentEpochs) {
                hasDelinquentLoans = true;
            }
        }

        uint256[] storage loanIds = p.userFixedLoanIds[positionKey];
        totalLoans = loanIds.length;
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                activeLoans++;
                totalDebt += loan.principalRemaining;
                if (nextExpiryTimestamp == 0 || loan.expiry < nextExpiryTimestamp) {
                    nextExpiryTimestamp = loan.expiry;
                }
                if (!hasDelinquentLoans && nowTs >= loan.expiry) {
                    hasDelinquentLoans = true;
                }
            }
        }

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        totalDebt += ds.directBorrowedPrincipal[positionKey][pid];
    }

    /// @notice Encumbrance breakdown for a Position NFT within a pool.
    function getPositionEncumbrance(uint256 tokenId, uint256 pid)
        external
        view
        returns (Types.PositionEncumbrance memory encumbrance)
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 totalEncumbered =
            enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;

        encumbrance = Types.PositionEncumbrance({
            directLocked: enc.directLocked,
            directLent: enc.directLent,
            directOfferEscrow: enc.directOfferEscrow,
            indexEncumbered: enc.indexEncumbered,
            totalEncumbered: totalEncumbered
        });
    }

    /// @notice Get paginated fixed-term loan IDs for a Position NFT
    function getPositionLoanIds(uint256 tokenId, uint256 pid, uint256 offset, uint256 limit)
        public
        view
        returns (uint256[] memory loanIds, uint256 totalCount, bool hasMore)
    {
        LibPositionHelpers.requireOwnership(tokenId);
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);

        uint256[] storage allLoanIds = p.userFixedLoanIds[positionKey];
        totalCount = allLoanIds.length;

        if (offset >= totalCount) {
            return (new uint256[](0), totalCount, false);
        }
        if (limit == 0) {
            hasMore = offset < totalCount;
            return (new uint256[](0), totalCount, hasMore);
        }

        uint256 remaining = totalCount - offset;
        if (limit > remaining) limit = remaining;

        loanIds = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            loanIds[i] = allLoanIds[offset + i];
        }
        hasMore = offset + limit < totalCount;
    }

    /// @notice Check if a Position NFT is delinquent
    function isPositionDelinquent(uint256 tokenId, uint256 pid) public view returns (bool) {
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        Types.RollingCreditLoan storage rollingLoan = p.rollingLoans[positionKey];

        if (rollingLoan.active) {
            (uint8 delinquentEpochs,) = _delinquencyThresholds();
            uint256 missedEpochs = _calculateMissedEpochs(rollingLoan);
            if (missedEpochs > 3) missedEpochs = 3;
            uint256 effectiveMissed = missedEpochs > rollingLoan.missedPayments ? missedEpochs : rollingLoan.missedPayments;
            if (effectiveMissed >= delinquentEpochs) {
                return true;
            }
        }

        uint256[] storage loanIds = p.userFixedLoanIds[positionKey];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed && block.timestamp >= loan.expiry) {
                return true;
            }
        }
        return false;
    }

    /// @notice Batch helper to fetch position state across multiple pools.
    function getPositionStates(uint256 tokenId, uint256[] calldata pids)
        external
        view
        returns (Types.PositionState[] memory states)
    {
        uint256 count = pids.length;
        states = new Types.PositionState[](count);
        for (uint256 i = 0; i < count; i++) {
            states[i] = getPositionState(tokenId, pids[i]);
        }
    }

    /// @notice Get metadata for a Position NFT
    function getPositionMetadata(uint256 tokenId, uint256 pid)
        public
        view
        returns (Types.PositionMetadata memory metadata)
    {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        Types.PoolData storage p = _pool(pid);

        metadata.tokenId = tokenId;
        metadata.poolId = pid;
        metadata.underlying = p.underlying;
        metadata.createdAt = nft.getCreationTime(tokenId);
        metadata.currentOwner = nft.ownerOf(tokenId);
    }

    /// @notice Batch fetch FixedTermLoan details for a set of loan IDs (explicit pool).
    function getLoansDetails(uint256 pid, uint256[] calldata loanIds)
        public
        view
        returns (Types.FixedTermLoan[] memory loans)
    {
        uint256 length = loanIds.length;
        loans = new Types.FixedTermLoan[](length);
        if (length == 0) {
            return loans;
        }

        Types.PoolData storage targetPool = _pool(pid);
        for (uint256 i = 0; i < length; i++) {
            uint256 loanId = loanIds[i];
            Types.FixedTermLoan storage loan = targetPool.fixedTermLoans[loanId];
            require(loan.borrower != bytes32(0), "PositionNFT: loan not found");
            loans[i] = loan;
        }
    }

    /// @notice Helper to expose selectors for deployment tooling
    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](8);
        selectorsArr[0] = bytes4(keccak256("getPositionState(uint256,uint256)"));
        selectorsArr[1] = bytes4(keccak256("getPositionSolvency(uint256,uint256)"));
        selectorsArr[2] = bytes4(keccak256("getPositionLoanSummary(uint256,uint256)"));
        selectorsArr[3] = bytes4(keccak256("getPositionLoanIds(uint256,uint256,uint256,uint256)"));
        selectorsArr[4] = bytes4(keccak256("isPositionDelinquent(uint256,uint256)"));
        selectorsArr[5] = bytes4(keccak256("getPositionMetadata(uint256,uint256)"));
        selectorsArr[6] = bytes4(keccak256("getLoansDetails(uint256,uint256[])"));
        selectorsArr[7] = bytes4(keccak256("getPositionEncumbrance(uint256,uint256)"));
    }

    function _computeDelinquencyFlags(
        Types.PoolData storage p,
        bytes32 positionKey,
        Types.RollingCreditLoan memory rollingLoan,
        uint256[] memory fixedLoanIds
    ) internal view returns (bool isDelinquent, bool eligibleForPenalty) {
        positionKey;
        if (rollingLoan.active) {
            (uint8 delinquentEpochs, uint8 penaltyEpochs) = _delinquencyThresholds();
            uint256 missedEpochs = _calculateMissedEpochsView(rollingLoan);
            if (missedEpochs > 3) missedEpochs = 3;
            uint256 effectiveMissed =
                missedEpochs > rollingLoan.missedPayments ? missedEpochs : rollingLoan.missedPayments;
            if (effectiveMissed >= delinquentEpochs) {
                isDelinquent = true;
            }
            if (effectiveMissed >= penaltyEpochs) {
                eligibleForPenalty = true;
            }
        }

        if (!eligibleForPenalty) {
            for (uint256 i = 0; i < fixedLoanIds.length; i++) {
                Types.FixedTermLoan storage loan = p.fixedTermLoans[fixedLoanIds[i]];
                if (!loan.closed && block.timestamp >= loan.expiry) {
                    isDelinquent = true;
                    eligibleForPenalty = true;
                    break;
                }
            }
        }
    }

}

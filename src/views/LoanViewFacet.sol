// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {Types} from "../libraries/Types.sol";

/// @notice Read-only views for loan state and previews
contract LoanViewFacet {
    function getRollingLoan(uint256 pid, bytes32 borrower) external view returns (Types.RollingCreditLoan memory) {
        return _pool(pid).rollingLoans[borrower];
    }

    function getFixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return _pool(pid).fixedTermLoans[loanId];
    }

    function previewBorrowRolling(uint256 pid, bytes32 borrower) external view returns (uint256 maxBorrow) {
        Types.PoolData storage p = _pool(pid);
        maxBorrow = (p.userPrincipal[borrower] * p.poolConfig.depositorLTVBps) / 10_000;
    }

    /// @notice Get all active fixed loan IDs for a borrower
    /// @dev Returns the array directly - O(1) lookup
    function getUserFixedLoanIds(uint256 pid, bytes32 borrower) external view returns (uint256[] memory) {
        return _pool(pid).userFixedLoanIds[borrower];
    }

    /// @notice Get paginated active fixed loan IDs for a borrower
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @param offset Starting index (0-based)
    /// @param limit Maximum number of loan IDs to return
    /// @return loanIds Array of loan IDs for the requested page
    /// @return total Total number of active loans for this borrower
    function getUserFixedLoanIdsPaginated(uint256 pid, bytes32 borrower, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory loanIds, uint256 total)
    {
        uint256[] storage allLoanIds = _pool(pid).userFixedLoanIds[borrower];
        total = allLoanIds.length;

        if (offset >= total) {
            return (new uint256[](0), total);
        }

        uint256 remaining = total - offset;
        if (limit > remaining) {
            limit = remaining;
        }

        loanIds = new uint256[](limit);
        for (uint256 i = 0; i < limit; ++i) {
            loanIds[i] = allLoanIds[offset + i];
        }
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](5);
        selectorsArr[0] = LoanViewFacet.getRollingLoan.selector;
        selectorsArr[1] = LoanViewFacet.getFixedLoan.selector;
        selectorsArr[2] = LoanViewFacet.previewBorrowRolling.selector;
        selectorsArr[3] = LoanViewFacet.getUserFixedLoanIds.selector;
        selectorsArr[4] = LoanViewFacet.getUserFixedLoanIdsPaginated.selector;
    }
}

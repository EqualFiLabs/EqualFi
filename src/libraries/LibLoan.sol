// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "./Types.sol";

/// @notice Helper functions for loan management
library LibLoan {
    /// @notice Remove a loan ID from a user's loan ID array
    /// @dev Uses swap-and-pop for O(1) removal
    function removeLoanId(Types.PoolData storage p, bytes32 borrower, uint256 loanId) internal {
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        uint256 length = loanIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (loanIds[i] == loanId) {
                // Replace with last element and pop
                loanIds[i] = loanIds[length - 1];
                loanIds.pop();
                break;
            }
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibLoanManager} from "./LibLoanManager.sol";

/// @notice Storage anchor for LibLoanManager state in the EqualLend Diamond.
library LibLoanManagerStorage {
    bytes32 internal constant LOAN_MANAGER_STORAGE_POSITION = keccak256("equal.lend.loan.manager.storage");

    struct LoanManagerStorage {
        mapping(uint256 => LibLoanManager.LoanManager) managers;
    }

    function s() internal pure returns (LoanManagerStorage storage ls) {
        bytes32 position = LOAN_MANAGER_STORAGE_POSITION;
        assembly {
            ls.slot := position
        }
    }
}


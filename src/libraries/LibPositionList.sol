// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibLoanManager} from "./LibLoanManager.sol";

/// @notice Thin wrapper around LibLoanManager for generic position-scoped linked lists.
/// @dev Provides consistent naming for Direct offers/agreements tracking.
library LibPositionList {
    using LibLoanManager for LibLoanManager.LoanManager;

    struct List {
        LibLoanManager.LoanManager manager;
    }

    function add(List storage self, bytes32 positionKey, uint256 id) internal {
        self.manager.addLoan(positionKey, id);
    }

    function remove(List storage self, bytes32 positionKey, uint256 id) internal {
        self.manager.removeLoan(positionKey, id);
    }

    function page(
        List storage self,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory ids, uint256 total) {
        return self.manager.getLoansByPosition(positionKey, offset, limit);
    }

    function meta(List storage self, bytes32 positionKey) internal view returns (uint256 head, uint256 tail, uint256 length) {
        return self.manager.getListMeta(positionKey);
    }

    function node(List storage self, bytes32 positionKey, uint256 id) internal view returns (uint256 prev, uint256 next, bool exists) {
        return self.manager.getNode(positionKey, id);
    }
}

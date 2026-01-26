// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Library for efficient per-position fixed-term loan management.
/// @dev Implements a doubly-linked list per position for O(1) insertions and deletions by loanId.
library LibLoanManager {
    struct LoanNode {
        uint256 prev;
        uint256 next;
        bool exists;
    }

    struct LoanList {
        uint256 head;
        uint256 tail;
        uint256 length;
        mapping(uint256 => LoanNode) loanNodes;
    }

    struct LoanManager {
        mapping(bytes32 => LoanList) lists;
    }

    /// @notice Add a loan to the end of a position's list.
    /// @dev Reverts if the loanId is already present for this position.
    function addLoan(
        LoanManager storage self,
        bytes32 positionKey,
        uint256 loanId
    ) internal {
        require(loanId != 0, "LoanManager: loanId=0");
        LoanList storage list = self.lists[positionKey];
        LoanNode storage node = list.loanNodes[loanId];
        require(!node.exists, "LoanManager: exists");

        node.exists = true;
        uint256 tailId = list.tail;
        if (tailId == 0) {
            // First node in list
            list.head = loanId;
            list.tail = loanId;
        } else {
            LoanNode storage tailNode = list.loanNodes[tailId];
            tailNode.next = loanId;
            node.prev = tailId;
            list.tail = loanId;
        }
        list.length += 1;
    }

    /// @notice Remove a loan from a position's list.
    /// @dev Reverts if the loanId is not present for this position.
    function removeLoan(
        LoanManager storage self,
        bytes32 positionKey,
        uint256 loanId
    ) internal {
        LoanList storage list = self.lists[positionKey];
        LoanNode storage node = list.loanNodes[loanId];
        require(node.exists, "LoanManager: missing");

        uint256 prevId = node.prev;
        uint256 nextId = node.next;

        if (prevId == 0) {
            // Removing head
            list.head = nextId;
        } else {
            list.loanNodes[prevId].next = nextId;
        }

        if (nextId == 0) {
            // Removing tail
            list.tail = prevId;
        } else {
            list.loanNodes[nextId].prev = prevId;
        }

        delete list.loanNodes[loanId];
        list.length -= 1;
    }

    /// @notice Get paginated loans for a position.
    /// @param positionKey Position identifier (e.g. positionKey for a Position NFT).
    /// @param offset Starting index in the list (0-based).
    /// @param limit Maximum number of loans to return (0 = until end).
    /// @return loanIds Array of loan IDs for the requested slice.
    /// @return total Total number of loans for this position.
    function getLoansByPosition(
        LoanManager storage self,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory loanIds, uint256 total) {
        LoanList storage list = self.lists[positionKey];
        total = list.length;
        if (offset >= total) {
            return (new uint256[](0), total);
        }

        uint256 remaining = total - offset;
        if (limit == 0 || limit > remaining) {
            limit = remaining;
        }

        loanIds = new uint256[](limit);
        uint256 current = list.head;
        for (uint256 i = 0; i < offset && current != 0; i++) {
            current = list.loanNodes[current].next;
        }

        for (uint256 i = 0; i < limit && current != 0; i++) {
            loanIds[i] = current;
            current = list.loanNodes[current].next;
        }
    }

    /// @notice Return list metadata for a position.
    /// @dev Intended for testing and introspection.
    function getListMeta(
        LoanManager storage self,
        bytes32 positionKey
    ) internal view returns (uint256 head, uint256 tail, uint256 length) {
        LoanList storage list = self.lists[positionKey];
        return (list.head, list.tail, list.length);
    }

    /// @notice Return node links for a given loan.
    /// @dev Intended for testing and introspection.
    function getNode(
        LoanManager storage self,
        bytes32 positionKey,
        uint256 loanId
    ) internal view returns (uint256 prev, uint256 next, bool exists) {
        LoanNode storage node = self.lists[positionKey].loanNodes[loanId];
        return (node.prev, node.next, node.exists);
    }
}

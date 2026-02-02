// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEncumbrance} from "../src/libraries/LibEncumbrance.sol";

contract EchidnaEncumbrance {
    // We need to use a fixed position and pool for stateful testing
    bytes32 internal constant TEST_POSITION = keccak256("test.position");
    uint256 internal constant TEST_POOL = 1;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;

    // Expose internal library functions via public harness
    function encumberIndex(uint256 indexId, uint256 amount) public {
        amount = amount % MAX_AMOUNT;
        LibEncumbrance.encumberIndex(TEST_POSITION, TEST_POOL, indexId, amount);
    }

    function unencumberIndex(uint256 indexId, uint256 amount) public {
        amount = amount % MAX_AMOUNT;
        // Only attempt if it won't revert (or let it revert to test safety)
        // For property testing, we might want to check reverts, but here we test state consistency
        try this.safeUnencumber(indexId, amount) {} catch {}
    }

    // Helper to allow try/catch
    function safeUnencumber(uint256 indexId, uint256 amount) external {
        LibEncumbrance.unencumberIndex(TEST_POSITION, TEST_POOL, indexId, amount);
    }

    // ========== INVARIANTS ==========

    /// @notice Index encumbrance must equal sum of individual indices
    /// @dev We track 3 arbitrary indices for this invariant
    function echidna_index_sum_consistency() public view returns (bool) {
        uint256 idx1 = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, 1);
        uint256 idx2 = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, 2);
        uint256 idx3 = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, 3);
        
        uint256 total = LibEncumbrance.getIndexEncumbered(TEST_POSITION, TEST_POOL);
        
        // The total stored in Encumbrance struct must be >= sum of checked indices
        // (It can be greater if other indices were touched by fuzzing)
        return total >= idx1 + idx2 + idx3;
    }

    /// @notice Total encumbrance must equal sum of components
    function echidna_total_matches_components() public view returns (bool) {
        uint256 total = LibEncumbrance.total(TEST_POSITION, TEST_POOL);
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(TEST_POSITION, TEST_POOL);
        
        return total == enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
    }

    /// @notice Unencumbering more than available must revert (handled by Echidna via try/catch in usage)
    /// Use a specific test to assert failure mode?
    function test_unencumber_underflow(uint256 indexId, uint256 amount) public {
        amount = amount % MAX_AMOUNT;
        uint256 current = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, indexId);
        
        if (amount > current) {
            try this.safeUnencumber(indexId, amount) {
                assert(false); // Should have reverted
            } catch {
                assert(true); // Correctly reverted
            }
        }
    }

    /// @notice Encumbering adds correctly to state
    function test_encumber_add(uint256 indexId, uint256 amount) public {
        amount = amount % MAX_AMOUNT;
        uint256 preTotal = LibEncumbrance.getIndexEncumbered(TEST_POSITION, TEST_POOL);
        uint256 preIndex = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, indexId);
        
        this.encumberIndex(indexId, amount);
        
        uint256 postTotal = LibEncumbrance.getIndexEncumbered(TEST_POSITION, TEST_POOL);
        uint256 postIndex = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, indexId);
        
        assert(postTotal == preTotal + amount);
        assert(postIndex == preIndex + amount);
    }
}

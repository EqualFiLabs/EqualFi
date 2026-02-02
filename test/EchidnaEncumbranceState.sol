// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEncumbrance} from "../src/libraries/LibEncumbrance.sol";
import {Types} from "../src/libraries/Types.sol";

/// @notice Stateful fuzzing for LibEncumbrance state transitions
/// @dev Echidna calls public functions in random sequences to find invalid states
contract EchidnaEncumbranceState {
    // Single user/pool scope for this campaign to maximize collision probability
    bytes32 internal constant TEST_POSITION = keccak256("test.position");
    uint256 internal constant TEST_POOL = 1;
    
    // Track expected state (Ghost variables) to verify library integrity
    uint256 internal ghost_principal;
    uint256 internal ghost_indexEncumbered;
    mapping(uint256 => uint256) internal ghost_indexEncumberedById;

    // Mock principal storage (normally in LibAppStorage, but we mock it here)
    // Since LibEncumbrance doesn't check principal (LibSolvencyChecks does),
    // we can manage principal separately to test the relationship.
    
    // ========== ACTIONS ==========

    /// @notice Simulate adding principal (Deposit)
    function action_deposit(uint128 amount) public {
        ghost_principal += amount;
    }

    /// @notice Simulate removing principal (Withdraw)
    function action_withdraw(uint128 amount) public {
        // Can only withdraw unencumbered principal
        uint256 encumbered = LibEncumbrance.total(TEST_POSITION, TEST_POOL);
        uint256 available = ghost_principal > encumbered ? ghost_principal - encumbered : 0;
        
        if (amount > available) return; // Echidna should learn to avoid this, or we just bound it
        
        ghost_principal -= amount;
    }

    /// @notice Encumber an index
    function action_encumber(uint8 indexId, uint128 amount) public {
        // Bound inputs
        if (amount == 0) return;
        
        // In the real system, Solvency checks would prevent this if it exceeds LTV/Principal
        // Here, we just want to test that LibEncumbrance tracks it correctly, 
        // even if it exceeds principal (since LibEncumbrance is just the accounting layer).
        // HOWEVER, to make the test meaningful for "solvency invariants", we might want to cap it.
        // Let's let it run free and just check consistency of the accounting.
        
        LibEncumbrance.encumberIndex(TEST_POSITION, TEST_POOL, indexId, amount);
        
        ghost_indexEncumbered += amount;
        ghost_indexEncumberedById[indexId] += amount;
    }

    /// @notice Unencumber an index
    function action_unencumber(uint8 indexId, uint128 amount) public {
        if (amount == 0) return;
        
        // Library reverts on underflow, so we wrap in try/catch or bound it
        // We want to verify it ONLY succeeds when valid
        
        uint256 current = LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, indexId);
        if (amount > current) {
            // Expect revert
            try this.safeUnencumber(indexId, amount) {
                assert(false); // Should have reverted
            } catch {
                // Correctly reverted
            }
        } else {
            // Expect success
            LibEncumbrance.unencumberIndex(TEST_POSITION, TEST_POOL, indexId, amount);
            ghost_indexEncumbered -= amount;
            ghost_indexEncumberedById[indexId] -= amount;
        }
    }

    // Helper for try/catch
    function safeUnencumber(uint256 indexId, uint256 amount) external {
        require(msg.sender == address(this), "onlySelf");
        LibEncumbrance.unencumberIndex(TEST_POSITION, TEST_POOL, indexId, amount);
    }

    // ========== INVARIANTS ==========

    /// @notice Ghost variable consistency: Total index encumbrance matches expected
    function echidna_invariant_ghost_total_match() public view returns (bool) {
        uint256 actual = LibEncumbrance.getIndexEncumbered(TEST_POSITION, TEST_POOL);
        return actual == ghost_indexEncumbered;
    }

    /// @notice Ghost variable consistency: Individual index encumbrance matches expected
    /// Check a few sample indices
    function echidna_invariant_ghost_index_match() public view returns (bool) {
        // Check indices 0..5 (fuzzer uses uint8 so it might pick large ones, but we can sample)
        // Since we can't iterate all mapping keys in solidity easily, we rely on the fuzzer 
        // to have mutated specific ones. Let's check a fixed set.
        for (uint8 i = 0; i < 5; i++) {
            if (LibEncumbrance.getIndexEncumberedForIndex(TEST_POSITION, TEST_POOL, i) != ghost_indexEncumberedById[i]) {
                return false;
            }
        }
        return true;
    }

    /// @notice Struct consistency: Total field matches sum of components
    function echidna_invariant_struct_consistency() public view returns (bool) {
        uint256 total = LibEncumbrance.total(TEST_POSITION, TEST_POOL);
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(TEST_POSITION, TEST_POOL);
        return total == enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
    }

    /// @notice State consistency: Encumbered amount never exceeds type(uint256).max (overflow check)
    /// Implicitly checked by solidity 0.8+, but good to have explicit property
    function echidna_invariant_no_overflow() public view returns (bool) {
        // Just reading the value ensures no panic occurred during the read
        LibEncumbrance.total(TEST_POSITION, TEST_POOL);
        return true;
    }
}

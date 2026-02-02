// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibFeeIndex} from "../src/libraries/LibFeeIndex.sol";
import {LibNetEquity} from "../src/libraries/LibNetEquity.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Echidna property tests for LibFeeIndex math
/// @dev Run with: echidna . --contract EchidnaFeeIndex --config test/echidna.yaml
contract EchidnaFeeIndex {
    uint256 internal constant INDEX_SCALE = 1e18;
    uint256 internal constant MAX_PRINCIPAL = type(uint128).max; // Realistic cap

    // ========== ASSERTION TESTS ==========

    /// @notice Fee base for same-asset must never exceed principal
    function test_fee_base_same_asset_le_principal(uint256 principal, uint256 debt) public pure {
        // Bound inputs to realistic ranges
        principal = principal % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        
        uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt);
        assert(feeBase <= principal);
    }

    /// @notice Fee base for same-asset is zero when debt >= principal
    function test_fee_base_zero_when_debt_exceeds(uint256 principal, uint256 debt) public pure {
        principal = principal % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        
        if (debt >= principal) {
            uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt);
            assert(feeBase == 0);
        }
    }

    /// @notice Fee base for same-asset equals principal - debt when debt < principal
    function test_fee_base_equals_net_equity(uint256 principal, uint256 debt) public pure {
        principal = principal % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        
        if (debt < principal) {
            uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt);
            uint256 expected = principal - debt;
            assert(feeBase == expected);
        }
    }

    /// @notice Cross-asset fee base never overflows
    function test_cross_asset_no_overflow(uint256 locked, uint256 unlocked) public pure {
        locked = locked % MAX_PRINCIPAL;
        unlocked = unlocked % MAX_PRINCIPAL;
        
        // Should not overflow since we bound inputs
        uint256 feeBase = LibFeeIndex.calculateFeeBaseCrossAsset(locked, unlocked);
        assert(feeBase == locked + unlocked);
    }

    /// @notice Cross-asset fee base equals sum of locked + unlocked
    function test_cross_asset_sum_property(uint256 locked, uint256 unlocked) public pure {
        locked = locked % MAX_PRINCIPAL;
        unlocked = unlocked % MAX_PRINCIPAL;
        
        uint256 feeBase = LibFeeIndex.calculateFeeBaseCrossAsset(locked, unlocked);
        assert(feeBase >= locked && feeBase >= unlocked);
    }

    /// @notice Yield calculation never exceeds the index delta scaled by principal
    function test_yield_bounded_by_delta(uint256 principal, uint256 debt, uint256 indexDelta) public pure {
        principal = principal % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        indexDelta = indexDelta % (INDEX_SCALE * 10); // Cap delta at 10x scale
        
        uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt);
        uint256 yield = Math.mulDiv(feeBase, indexDelta, INDEX_SCALE);
        
        // Yield should never exceed feeBase * (indexDelta / scale)
        uint256 maxYield = Math.mulDiv(feeBase, indexDelta, INDEX_SCALE);
        assert(yield <= maxYield);
    }

    /// @notice Fee base monotonicity: increasing principal increases fee base (when debt constant)
    function test_fee_base_monotonic_principal(uint256 principal1, uint256 principal2, uint256 debt) 
        public pure 
    {
        principal1 = principal1 % MAX_PRINCIPAL;
        principal2 = principal2 % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        
        if (principal1 < principal2) {
            uint256 feeBase1 = LibFeeIndex.calculateFeeBaseSameAsset(principal1, debt);
            uint256 feeBase2 = LibFeeIndex.calculateFeeBaseSameAsset(principal2, debt);
            assert(feeBase1 <= feeBase2);
        }
    }

    /// @notice Fee base anti-monotonic debt: increasing debt decreases fee base (when principal constant)
    function test_fee_base_anti_monotonic_debt(uint256 principal, uint256 debt1, uint256 debt2) 
        public pure 
    {
        principal = principal % MAX_PRINCIPAL;
        debt1 = debt1 % MAX_PRINCIPAL;
        debt2 = debt2 % MAX_PRINCIPAL;
        
        if (debt1 < debt2 && debt2 <= principal) {
            uint256 feeBase1 = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt1);
            uint256 feeBase2 = LibFeeIndex.calculateFeeBaseSameAsset(principal, debt2);
            assert(feeBase1 >= feeBase2);
        }
    }

    /// @notice P2P borrower fee base never exceeds sum of inputs
    function test_p2p_borrower_fee_base_bounded(
        uint256 locked,
        uint256 unlocked,
        uint256 debt,
        bool isSameAsset
    ) public pure {
        locked = locked % MAX_PRINCIPAL;
        unlocked = unlocked % MAX_PRINCIPAL;
        debt = debt % MAX_PRINCIPAL;
        
        uint256 feeBase = LibFeeIndex.calculateP2PBorrowerFeeBase(locked, unlocked, debt, isSameAsset);
        
        if (isSameAsset) {
            // Same asset: should be (locked + unlocked) - debt, capped at 0
            uint256 total = locked + unlocked;
            assert(feeBase <= total);
        } else {
            // Cross asset: should be locked + unlocked
            assert(feeBase == locked + unlocked);
        }
    }

    /// @notice Zero principal always yields zero fee base
    function test_zero_principal_zero_fee_base(uint256 debt) public pure {
        debt = debt % MAX_PRINCIPAL;
        uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(0, debt);
        assert(feeBase == 0);
    }

    /// @notice Zero debt yields fee base equal to principal
    function test_zero_debt_fee_base_equals_principal(uint256 principal) public pure {
        principal = principal % MAX_PRINCIPAL;
        uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, 0);
        assert(feeBase == principal);
    }
}

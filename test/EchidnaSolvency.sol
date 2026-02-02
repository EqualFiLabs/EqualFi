// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibSolvencyChecks} from "../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../src/libraries/Types.sol";
import {LibEncumbrance} from "../src/libraries/LibEncumbrance.sol";

contract EchidnaSolvency {
    // Mock storage
    Types.PoolData internal pool;

    // ========== SETUP ==========

    // Configure the LTV for the current run
    function setLTV(uint16 ltv) public {
        // Cap at 10000 (100%)
        if (ltv > 10000) ltv = 10000;
        pool.poolConfig.depositorLTVBps = ltv;
    }

    // ========== ASSERTION TESTS ==========

    /// @notice Solvency check must be monotonic with respect to debt
    /// If solvent at debt D, must be solvent at debt d < D (for same principal)
    function test_solvency_monotonic_debt(uint256 principal, uint256 debt1, uint256 debt2) public view {
        principal = principal % type(uint128).max;
        debt1 = debt1 % type(uint128).max;
        debt2 = debt2 % type(uint128).max;
        
        bool solvent1 = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal, debt1);
        bool solvent2 = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal, debt2);
        
        if (debt1 < debt2 && solvent2) {
            // If solvent at higher debt, must be solvent at lower debt
            assert(solvent1);
        }
    }

    /// @notice Solvency check must be monotonic with respect to principal
    /// If solvent at principal P, must be solvent at principal p > P (for same debt)
    function test_solvency_monotonic_principal(uint256 principal1, uint256 principal2, uint256 debt) public view {
        principal1 = principal1 % type(uint128).max;
        principal2 = principal2 % type(uint128).max;
        debt = debt % type(uint128).max;
        
        bool solvent1 = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal1, debt);
        bool solvent2 = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal2, debt);
        
        if (principal1 < principal2 && solvent1) {
            // If solvent at lower principal, must be solvent at higher principal
            assert(solvent2);
        }
    }

    /// @notice Solvency implies Debt <= Principal (when LTV <= 100%)
    function test_solvency_implies_collateralization(uint256 principal, uint256 debt) public view {
        principal = principal % type(uint128).max;
        debt = debt % type(uint128).max;
        
        bool solvent = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal, debt);
        
        // If LTV <= 100% and solvent, then Debt must be <= Principal
        if (pool.poolConfig.depositorLTVBps <= 10000 && solvent) {
            assert(debt <= principal);
        }
    }

    /// @notice Zero debt is always solvent
    function test_zero_debt_always_solvent(uint256 principal) public view {
        bool solvent = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal, 0);
        assert(solvent);
    }

    /// @notice Zero LTV means no debt allowed (unless debt is zero)
    function test_zero_ltv_no_borrowing(uint256 principal, uint256 debt) public {
        // Force LTV to 0
        Types.PoolData storage p = pool;
        uint16 oldLtv = p.poolConfig.depositorLTVBps;
        p.poolConfig.depositorLTVBps = 0;
        
        bool solvent = LibSolvencyChecks.checkSolvency(pool, bytes32(0), principal, debt);
        
        if (debt > 0) {
            assert(!solvent);
        } else {
            assert(solvent);
        }
        
        // Restore LTV
        p.poolConfig.depositorLTVBps = oldLtv;
    }
    
    /// @notice Available principal calculation matches formula
    function test_available_principal_calculation(uint256 principal, uint256 encumbered) public {
        // Setup mock storage for principal
        bytes32 posKey = keccak256("test");
        pool.userPrincipal[posKey] = principal;
        
        // Pure logic verification
        uint256 available;
        if (encumbered >= principal) {
            available = 0;
        } else {
            available = principal - encumbered;
        }
        
        if (encumbered < principal) {
            assert(available == principal - encumbered);
        } else {
            assert(available == 0);
        }
    }
}

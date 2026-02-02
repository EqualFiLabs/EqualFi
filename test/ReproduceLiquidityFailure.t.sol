// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {EchidnaLendingFacet} from "./EchidnaLendingFacet.sol";

contract ReproduceLiquidityFailure is Test {
    EchidnaLendingFacet facet;

    function setUp() public {
        facet = new EchidnaLendingFacet();
    }

    function test_ReproduceInvariantFailure() public {
        uint128 depositAmount = 1346746830706240228723223072239472304;
        uint128 borrowAmount = 256;

        console2.log("=== Initial State ===");
        logState();

        console2.log(">>> Action: Deposit", depositAmount);
        facet.action_deposit(depositAmount);
        logState();

        console2.log(">>> Action: Borrow", borrowAmount);
        facet.action_borrow(borrowAmount);
        logState();

        bool invariant = facet.echidna_liquidity_invariant();
        console2.log("Invariant passed?", invariant);
        
        assertTrue(invariant, "Liquidity invariant failed");
    }

    function logState() internal view {
        (uint256 tracked, uint256 reserve, uint256 remainder, uint256 actual) = facet.debug_accounting();
        console2.log("Tracked:  ", tracked);
        console2.log("Reserve:  ", reserve);
        console2.log("Remainder:", remainder);
        console2.log("Internal: ", tracked + reserve + remainder);
        console2.log("Actual:   ", actual);
        int256 diff = int256(tracked + reserve + remainder) - int256(actual);
        console2.log("Diff:     ");
        console2.logInt(diff);
    }
}

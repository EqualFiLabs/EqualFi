// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibReentrancyGuard, ReentrancyGuardModifiers} from "../../src/libraries/LibReentrancyGuard.sol";

contract ReentrancyGuardHarness is ReentrancyGuardModifiers {
    function guardedCall(address attacker) external nonReentrant {
        if (attacker != address(0)) {
            ReentrancyAttacker(attacker).reenter(address(this));
        }
    }
}

contract ReentrancyAttacker {
    function reenter(address target) external {
        ReentrancyGuardHarness(target).guardedCall(address(0));
    }
}

contract LibReentrancyGuardTest is Test {
    function test_nonReentrant_revertsOnReentry() public {
        ReentrancyGuardHarness h = new ReentrancyGuardHarness();
        ReentrancyAttacker attacker = new ReentrancyAttacker();

        vm.expectRevert(LibReentrancyGuard.ReentrancyGuard_ReentrantCall.selector);
        h.guardedCall(address(attacker));
    }

    function test_nonReentrant_allowsFreshEntryAfterRevert() public {
        ReentrancyGuardHarness h = new ReentrancyGuardHarness();
        ReentrancyAttacker attacker = new ReentrancyAttacker();

        vm.expectRevert(LibReentrancyGuard.ReentrancyGuard_ReentrantCall.selector);
        h.guardedCall(address(attacker));

        // Guard should be reset after revert and allow a clean call.
        h.guardedCall(address(0));
    }
}


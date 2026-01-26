// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract WithdrawableEquityConservationHarness {
    function seedPool(uint256 pid, address underlying, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.trackedBalance = trackedBalance;
    }

    function setUser(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }

    function setLocks(bytes32 positionKey, uint256 pid, uint256 locked, uint256 escrow) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = escrow;
    }

    function withdrawable(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateWithdrawablePrincipal(p, positionKey, pid);
    }
}

contract WithdrawableEquityConservationPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 6: Withdrawable Equity Conservation
    function testFuzz_withdrawableEquityConservation(
        uint256 principal,
        uint256 locked,
        uint256 escrow,
        uint256 balance
    ) public {
        vm.assume(principal <= type(uint256).max - locked);
        vm.assume(locked <= principal);
        vm.assume(escrow <= principal - locked);
        vm.assume(balance >= principal - locked - escrow);

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        WithdrawableEquityConservationHarness harness = new WithdrawableEquityConservationHarness();
        bytes32 positionKey = bytes32(uint256(0xBEEF));
        uint256 pid = 1;

        harness.seedPool(pid, address(token), balance);
        harness.setUser(pid, positionKey, principal);
        harness.setLocks(positionKey, pid, locked, escrow);
        token.mint(address(harness), balance);

        uint256 withdrawable = harness.withdrawable(pid, positionKey);
        uint256 poolBalance = token.balanceOf(address(harness));
        assertLe(withdrawable, poolBalance, "withdrawable exceeds pool balance");
    }
}

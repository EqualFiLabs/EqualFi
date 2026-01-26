// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LibSolvencyChecksHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function setRollingLoan(uint256 pid, bytes32 positionKey, uint256 principalRemaining, bool active) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principalRemaining = principalRemaining;
        loan.active = active;
    }

    function setFixedDebt(uint256 pid, bytes32 positionKey, uint256 totalPrincipalRemaining) external {
        s().pools[pid].fixedTermPrincipalRemaining[positionKey] = totalPrincipalRemaining;
    }

    function loanDebts(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 rollingDebt, uint256 fixedDebt, uint256 totalLoanDebt)
    {
        Types.PoolData storage p = s().pools[pid];
        return LibSolvencyChecks.calculateLoanDebts(p, positionKey);
    }
}

contract LibSolvencyChecksPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 2: Pool-Native Debt Tracking
    function testFuzz_poolNativeDebtTracking(
        uint256 rollingStart,
        uint256 rollingBorrow,
        uint256 rollingRepay,
        uint256 fixedStart,
        uint256 fixedBorrow,
        uint256 fixedRepay
    ) public {
        LibSolvencyChecksHarness harness = new LibSolvencyChecksHarness();
        uint256 pid = 1;
        bytes32 positionKey = bytes32(uint256(0xBEEF));

        vm.assume(rollingStart <= type(uint256).max - rollingBorrow);
        uint256 rollingAfterBorrow = rollingStart + rollingBorrow;
        vm.assume(rollingRepay <= rollingAfterBorrow);
        uint256 rollingAfterRepay = rollingAfterBorrow - rollingRepay;

        vm.assume(fixedStart <= type(uint256).max - fixedBorrow);
        uint256 fixedAfterBorrow = fixedStart + fixedBorrow;
        vm.assume(fixedRepay <= fixedAfterBorrow);
        uint256 fixedAfterRepay = fixedAfterBorrow - fixedRepay;
        vm.assume(rollingStart <= type(uint256).max - fixedStart);

        harness.setRollingLoan(pid, positionKey, rollingStart, rollingStart > 0);
        harness.setFixedDebt(pid, positionKey, fixedStart);
        (uint256 rollingDebt, uint256 fixedDebt, uint256 totalDebt) = harness.loanDebts(pid, positionKey);
        assertEq(rollingDebt, rollingStart, "rolling debt mismatch");
        assertEq(fixedDebt, fixedStart, "fixed debt mismatch");
        assertEq(totalDebt, rollingStart + fixedStart, "total debt mismatch");

        vm.assume(rollingAfterBorrow <= type(uint256).max - fixedAfterBorrow);
        harness.setRollingLoan(pid, positionKey, rollingAfterBorrow, rollingAfterBorrow > 0);
        harness.setFixedDebt(pid, positionKey, fixedAfterBorrow);
        (rollingDebt, fixedDebt, totalDebt) = harness.loanDebts(pid, positionKey);
        assertEq(rollingDebt, rollingAfterBorrow, "rolling borrow mismatch");
        assertEq(fixedDebt, fixedAfterBorrow, "fixed borrow mismatch");
        assertEq(totalDebt, rollingAfterBorrow + fixedAfterBorrow, "total borrow mismatch");

        vm.assume(rollingAfterRepay <= type(uint256).max - fixedAfterRepay);
        harness.setRollingLoan(pid, positionKey, rollingAfterRepay, rollingAfterRepay > 0);
        harness.setFixedDebt(pid, positionKey, fixedAfterRepay);
        (rollingDebt, fixedDebt, totalDebt) = harness.loanDebts(pid, positionKey);
        assertEq(rollingDebt, rollingAfterRepay, "rolling repay mismatch");
        assertEq(fixedDebt, fixedAfterRepay, "fixed repay mismatch");
        assertEq(totalDebt, rollingAfterRepay + fixedAfterRepay, "total repay mismatch");
    }
}

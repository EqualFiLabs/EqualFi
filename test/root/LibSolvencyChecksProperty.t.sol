// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

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

    function setPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        s().pools[pid].userPrincipal[positionKey] = principal;
    }

    function setDirectEncumbrance(
        bytes32 positionKey,
        uint256 pid,
        uint256 directLocked,
        uint256 directLent,
        uint256 directOfferEscrow
    ) external {
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, pid);
        enc.directLocked = directLocked;
        enc.directLent = directLent;
        enc.directOfferEscrow = directOfferEscrow;
    }

    function encumberIndex(bytes32 positionKey, uint256 pid, uint256 indexId, uint256 amount) external {
        LibEncumbrance.encumberIndex(positionKey, pid, indexId, amount);
    }

    function encumberModule(bytes32 positionKey, uint256 pid, uint256 moduleId, uint256 amount) external {
        LibEncumbrance.encumberModule(positionKey, pid, moduleId, amount);
    }

    function availablePrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibSolvencyChecks.calculateAvailablePrincipal(s().pools[pid], positionKey, pid);
    }
}

contract LibSolvencyChecksPropertyTest is Test {
    uint256 internal constant INDEX_ID = 77;
    uint256 internal constant MODULE_ID = 88;

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

    function test_availablePrincipal_includesModuleEncumbered() public {
        LibSolvencyChecksHarness harness = new LibSolvencyChecksHarness();
        uint256 pid = 2;
        bytes32 positionKey = bytes32(uint256(0xCAFE));

        harness.setPrincipal(pid, positionKey, 1000);
        harness.setDirectEncumbrance(positionKey, pid, 100, 50, 25);
        harness.encumberIndex(positionKey, pid, INDEX_ID, 200);
        harness.encumberModule(positionKey, pid, MODULE_ID, 125);

        assertEq(harness.availablePrincipal(pid, positionKey), 500, "module encumbrance must reduce availability");
    }

    function test_availablePrincipal_returnsZeroWhenModuleEncumbranceExceedsPrincipal() public {
        LibSolvencyChecksHarness harness = new LibSolvencyChecksHarness();
        uint256 pid = 3;
        bytes32 positionKey = bytes32(uint256(0xD00D));

        harness.setPrincipal(pid, positionKey, 100);
        harness.encumberModule(positionKey, pid, MODULE_ID, 101);

        assertEq(harness.availablePrincipal(pid, positionKey), 0, "availability floors at zero");
    }
}

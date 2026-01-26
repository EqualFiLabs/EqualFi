// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";

contract EncumberedYieldHarness {
    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setUser(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function encumber(bytes32 positionKey, uint256 pid, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(positionKey, pid, indexId, amount);
    }

    function accrue(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("TEST_FEE"));
    }

    function settle(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function accrued(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }
}

contract EncumberedYieldAccrualPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 9: Encumbered Principal Earns Yield
    function testFuzz_encumberedPrincipalEarnsYield(uint256 principal, uint256 encumbered, uint256 fee) public {
        principal = bound(principal, 1, 1e24);
        encumbered = bound(encumbered, 1, principal);
        fee = bound(fee, 1, 1e24);

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        EncumberedYieldHarness harness = new EncumberedYieldHarness();
        bytes32 positionKey = bytes32(uint256(0xBEEF));

        uint256 pidEncumbered = 1;
        uint256 pidPlain = 2;

        harness.seedPool(pidEncumbered, address(token), principal);
        harness.seedPool(pidPlain, address(token), principal);
        harness.setUser(pidEncumbered, positionKey, principal);
        harness.setUser(pidPlain, positionKey, principal);

        uint256 trackedBefore = harness.trackedBalance(pidEncumbered);
        harness.encumber(positionKey, pidEncumbered, 7, encumbered);
        assertEq(harness.trackedBalance(pidEncumbered), trackedBefore);

        harness.accrue(pidEncumbered, fee);
        harness.accrue(pidPlain, fee);
        harness.settle(pidEncumbered, positionKey);
        harness.settle(pidPlain, positionKey);

        uint256 encumberedYield = harness.accrued(pidEncumbered, positionKey);
        uint256 plainYield = harness.accrued(pidPlain, positionKey);
        assertEq(encumberedYield, plainYield);
    }
}

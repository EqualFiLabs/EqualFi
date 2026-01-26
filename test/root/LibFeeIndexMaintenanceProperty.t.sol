// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LibFeeIndexMaintenancePropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 12: Maintenance Fee Ordering
    function test_maintenanceAppliedBeforeFeeBase() public {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 pid = 1;
        bytes32 positionKey = bytes32(uint256(0xBEEF));

        Types.PoolData storage p = store.pools[pid];
        p.underlying = address(0xA11CE);
        p.initialized = true;
        p.feeIndex = 2e18;
        p.maintenanceIndex = 1e18 + 1e17; // +0.1
        p.userFeeIndex[positionKey] = 1e18;
        p.userMaintenanceIndex[positionKey] = 1e18;
        p.userPrincipal[positionKey] = 100 ether;
        p.rollingLoans[positionKey].active = true;
        p.rollingLoans[positionKey].principalRemaining = 30 ether;

        LibFeeIndex.settle(pid, positionKey);

        assertEq(p.userPrincipal[positionKey], 90 ether, "maintenance not applied first");
        assertEq(p.userAccruedYield[positionKey], 60 ether, "fee base not recalculated");
    }
}

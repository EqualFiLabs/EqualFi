// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";

contract ManagedPoolSystemShareGovernanceHarness is AdminGovernanceFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function currentManagedPoolSystemShareBps() external view returns (uint16) {
        return LibAppStorage.managedPoolSystemShareBps(LibAppStorage.s());
    }
}

contract ManagedPoolSystemShareGovernancePropertyTest is Test {
    ManagedPoolSystemShareGovernanceHarness internal facet;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);

    function setUp() public {
        facet = new ManagedPoolSystemShareGovernanceHarness();
        facet.setOwner(OWNER);
        facet.setTimelock(TIMELOCK);
    }

    /// **Feature: managed-pool-system-share, Property 2: Governance Validation Rejects Invalid BPS**
    function testFuzz_governanceValidationRejectsInvalidBps(uint16 bps) public {
        bps = uint16(bound(bps, 10_001, type(uint16).max));

        vm.prank(OWNER);
        vm.expectRevert("EqualFi: share>100%");
        facet.setManagedPoolSystemShareBps(bps);
    }

    /// **Feature: managed-pool-system-share, Property 3: Access Control Enforcement**
    function testFuzz_accessControlEnforcement(address caller) public {
        vm.assume(caller != OWNER && caller != TIMELOCK);

        vm.prank(caller);
        vm.expectRevert("LibAccess: not owner or timelock");
        facet.setManagedPoolSystemShareBps(1_000);
    }

    /// **Feature: managed-pool-system-share, Property 4: Governance Event Emission**
    function testFuzz_governanceEventEmission(uint16 newBps) public {
        newBps = uint16(bound(newBps, 0, 10_000));
        uint16 oldBps = facet.currentManagedPoolSystemShareBps();

        vm.prank(OWNER);
        vm.expectEmit(false, false, false, true);
        emit AdminGovernanceFacet.ManagedPoolSystemShareUpdated(oldBps, newBps);
        facet.setManagedPoolSystemShareBps(newBps);
    }
}

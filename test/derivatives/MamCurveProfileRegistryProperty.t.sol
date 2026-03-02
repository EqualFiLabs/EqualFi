// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";

contract MamCurveProfileRegistryHarness is MamCurveCreationFacet {
    function setOwner(address owner_) external {
        LibDiamond.diamondStorage().contractOwner = owner_;
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }
}

contract MamCurveProfileRegistryPropertyTest is Test {
    event CurveProfileApproved(address indexed profile);
    event CurveProfileRevoked(address indexed profile);

    MamCurveProfileRegistryHarness internal harness;

    address internal owner = address(0xA11CE);
    address internal timelock = address(0xB0B);

    function setUp() public {
        harness = new MamCurveProfileRegistryHarness();
        harness.setOwner(owner);
        harness.setTimelock(timelock);
    }

    // Property 4: Profile approve/revoke round-trip
    function testFuzz_profileApproveRevokeRoundTrip(address profile) public {
        assertFalse(harness.isCurveProfileApproved(profile));

        vm.expectEmit(true, false, false, true, address(harness));
        emit CurveProfileApproved(profile);
        vm.prank(owner);
        harness.approveCurveProfile(profile);
        assertTrue(harness.isCurveProfileApproved(profile));

        vm.expectEmit(true, false, false, true, address(harness));
        emit CurveProfileRevoked(profile);
        vm.prank(owner);
        harness.revokeCurveProfile(profile);
        assertFalse(harness.isCurveProfileApproved(profile));
    }

    // Property 5: Non-governance cannot modify profile registry
    function testFuzz_nonGovernanceCannotModifyProfileRegistry(address caller, address profile) public {
        vm.assume(caller != owner && caller != timelock);

        vm.prank(caller);
        vm.expectRevert();
        harness.approveCurveProfile(profile);

        vm.prank(caller);
        vm.expectRevert();
        harness.revokeCurveProfile(profile);
    }

    function test_timelockCanModifyProfileRegistry(address profile) public {
        vm.prank(timelock);
        harness.approveCurveProfile(profile);
        assertTrue(harness.isCurveProfileApproved(profile));

        vm.prank(timelock);
        harness.revokeCurveProfile(profile);
        assertFalse(harness.isCurveProfileApproved(profile));
    }
}

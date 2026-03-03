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
    event CurveProfileSet(uint16 indexed profileId, address impl, uint32 flags, bool approved);

    MamCurveProfileRegistryHarness internal harness;

    address internal owner = address(0xA11CE);
    address internal timelock = address(0xB0B);

    function setUp() public {
        harness = new MamCurveProfileRegistryHarness();
        harness.setOwner(owner);
        harness.setTimelock(timelock);
    }

    // Property 4: Profile approve/revoke round-trip
    function testFuzz_profileApproveRevokeRoundTrip(uint16 profileIdRaw, address impl, uint32 flags) public {
        uint16 profileId = uint16(bound(profileIdRaw, 2, type(uint16).max));
        vm.assume(impl != address(0));

        assertFalse(harness.isCurveProfileApproved(profileId));

        vm.expectEmit(true, false, false, true, address(harness));
        emit CurveProfileSet(profileId, impl, flags, true);
        vm.prank(owner);
        harness.setCurveProfile(profileId, impl, flags, true);
        assertTrue(harness.isCurveProfileApproved(profileId));
        (address storedImpl, uint32 storedFlags, bool approved) = harness.getCurveProfile(profileId);
        assertEq(storedImpl, impl);
        assertEq(storedFlags, flags);
        assertTrue(approved);

        vm.expectEmit(true, false, false, true, address(harness));
        emit CurveProfileSet(profileId, impl, flags, false);
        vm.prank(owner);
        harness.setCurveProfile(profileId, impl, flags, false);
        assertFalse(harness.isCurveProfileApproved(profileId));
    }

    // Property 5: Non-governance cannot modify profile registry
    function testFuzz_nonGovernanceCannotModifyProfileRegistry(address caller, uint16 profileIdRaw, address impl)
        public
    {
        vm.assume(caller != owner && caller != timelock);
        uint16 profileId = uint16(bound(profileIdRaw, 2, type(uint16).max));
        vm.assume(impl != address(0));

        vm.prank(caller);
        vm.expectRevert();
        harness.setCurveProfile(profileId, impl, 0, true);
    }

    function test_timelockCanModifyProfileRegistry(uint16 profileIdRaw, address impl) public {
        uint16 profileId = uint16(bound(profileIdRaw, 2, type(uint16).max));
        vm.assume(impl != address(0));

        vm.prank(timelock);
        harness.setCurveProfile(profileId, impl, 0, true);
        assertTrue(harness.isCurveProfileApproved(profileId));

        vm.prank(timelock);
        harness.setCurveProfile(profileId, impl, 0, false);
        assertFalse(harness.isCurveProfileApproved(profileId));
    }

    function test_builtinLinearProfileApprovedByDefault() public {
        assertTrue(harness.isCurveProfileApproved(1));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PoolMembershipRequired,
    MembershipAlreadyExists,
    CannotClearMembership
} from "../../src/libraries/Errors.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";

contract PoolMembershipHarness {
    function ensure(bytes32 positionKey, uint256 pid, bool allowAutoJoin) external returns (bool) {
        return LibPoolMembership._ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }

    function join(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function leave(bytes32 positionKey, uint256 pid, bool canClear, string memory reason) external {
        LibPoolMembership._leavePool(positionKey, pid, canClear, reason);
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }
}

contract LibPoolMembershipTest is Test {
    PoolMembershipHarness internal harness;
    bytes32 internal constant POSITION = keccak256("POSITION");
    uint256 internal constant POOL_ID = 42;

    function setUp() public {
        harness = new PoolMembershipHarness();
    }

    function test_EnsureAutoJoinsWhenAllowed() public {
        bool alreadyMember = harness.ensure(POSITION, POOL_ID, true);
        assertFalse(alreadyMember, "Should mark as new membership");
        assertTrue(harness.isMember(POSITION, POOL_ID), "Membership should be recorded");
    }

    function test_EnsureRevertsWhenMissingAndAutoJoinDisabled() public {
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, POSITION, POOL_ID));
        harness.ensure(POSITION, POOL_ID, false);
    }

    function test_EnsureReturnsTrueWhenMembershipExists() public {
        harness.ensure(POSITION, POOL_ID, true);
        bool alreadyMember = harness.ensure(POSITION, POOL_ID, false);
        assertTrue(alreadyMember, "Should report existing membership");
    }

    function test_JoinPoolRevertsOnDuplicate() public {
        harness.join(POSITION, POOL_ID);
        vm.expectRevert(abi.encodeWithSelector(MembershipAlreadyExists.selector, POSITION, POOL_ID));
        harness.join(POSITION, POOL_ID);
    }

    function test_LeavePoolClearsMembership() public {
        harness.ensure(POSITION, POOL_ID, true);
        harness.leave(POSITION, POOL_ID, true, "");
        assertFalse(harness.isMember(POSITION, POOL_ID), "Membership should be cleared");
    }

    function test_LeavePoolRevertsWhenNotClearable() public {
        harness.ensure(POSITION, POOL_ID, true);
        string memory reason = "outstanding obligations";
        vm.expectRevert(abi.encodeWithSelector(CannotClearMembership.selector, POSITION, POOL_ID, reason));
        harness.leave(POSITION, POOL_ID, false, reason);
        assertTrue(harness.isMember(POSITION, POOL_ID), "Membership remains when not cleared");
    }

    function test_LeavePoolRevertsWhenNotMember() public {
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, POSITION, POOL_ID));
        harness.leave(POSITION, POOL_ID, true, "");
    }
}

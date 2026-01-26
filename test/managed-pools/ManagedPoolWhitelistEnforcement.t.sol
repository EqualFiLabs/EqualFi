// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {WhitelistRequired, PoolMembershipRequired} from "../../src/libraries/Errors.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

contract PoolMembershipHarness {
    function seedManagedPool(uint256 pid, bool whitelistEnabled) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.isManagedPool = true;
        p.whitelistEnabled = whitelistEnabled;
    }

    function seedWhitelist(uint256 pid, bytes32 positionKey, bool allowed) external {
        LibAppStorage.s().pools[pid].whitelist[positionKey] = allowed;
    }

    function seedMembership(uint256 pid, bytes32 positionKey) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function ensure(bytes32 positionKey, uint256 pid, bool allowAutoJoin) external returns (bool) {
        return LibPoolMembership._ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }
}

/// **Feature: managed-pools, Property 4: Whitelist enforcement across operations**
/// **Validates: Requirements 3.1, 5.1, 5.2, 5.3, 5.4, 5.5**
contract ManagedPoolWhitelistEnforcementPropertyTest is Test {
    PoolMembershipHarness internal harness;
    address internal user = address(0xB0B);
    address internal whitelisted = address(0xA11CE);

    function setUp() public {
        harness = new PoolMembershipHarness();
    }

    function testProperty_WhitelistEnforcementAcrossOperations() public {
        bytes32 userKey = LibPositionHelpers.systemPositionKey(user);
        bytes32 whitelistedKey = LibPositionHelpers.systemPositionKey(whitelisted);
        harness.seedManagedPool(1, true);
        harness.seedWhitelist(1, whitelistedKey, true);

        vm.expectRevert(abi.encodeWithSelector(WhitelistRequired.selector, userKey, 1));
        harness.ensure(userKey, 1, true);

        assertFalse(LibPoolMembership.isMember(userKey, 1), "non-member not joined");

        bool alreadyMember = harness.ensure(whitelistedKey, 1, true);
        assertFalse(alreadyMember, "first join");
        bool secondCall = harness.ensure(whitelistedKey, 1, true);
        assertTrue(secondCall, "whitelisted member joined");

        harness.seedManagedPool(2, false); // whitelist disabled
        bool unmanagedJoin = harness.ensure(userKey, 2, true);
        assertFalse(unmanagedJoin, "auto join when whitelist off");
        bool unmanagedSecond = harness.ensure(userKey, 2, true);
        assertTrue(unmanagedSecond, "joined when whitelist disabled");

        harness.seedManagedPool(3, true);
        harness.seedWhitelist(3, userKey, true);
        bool joinResult = harness.ensure(userKey, 3, true);
        assertFalse(joinResult, "joined managed pool with whitelist");
    }
}

/// **Feature: managed-pools, Property 8: Recovery operation accessibility**
/// **Validates: Requirements 5.6**
contract ManagedPoolRecoveryAccessibilityPropertyTest is Test {
    PoolMembershipHarness internal harness;
    address internal user = address(0xBEEF);

    function setUp() public {
        harness = new PoolMembershipHarness();
        harness.seedManagedPool(5, true);
        bytes32 userKey = LibPositionHelpers.systemPositionKey(user);
        harness.seedWhitelist(5, userKey, true);
        harness.ensure(userKey, 5, true);
        harness.seedWhitelist(5, userKey, false); // simulate removal from whitelist
    }

    function testProperty_RecoveriesNotBlockedByWhitelistRemoval() public {
        // Existing membership should allow operations even if removed from whitelist
        bytes32 userKey = LibPositionHelpers.systemPositionKey(user);
        bool alreadyMember = harness.ensure(userKey, 5, false);
        assertTrue(alreadyMember, "existing membership preserved");
    }

    function testProperty_RecoveriesBlockedForNonMemberWhenWhitelistEnabled() public {
        address outsider = address(0xD00D);
        bytes32 outsiderKey = LibPositionHelpers.systemPositionKey(outsider);
        vm.expectRevert(abi.encodeWithSelector(WhitelistRequired.selector, outsiderKey, 5));
        harness.ensure(outsiderKey, 5, true);

        vm.expectRevert(abi.encodeWithSelector(WhitelistRequired.selector, outsiderKey, 5));
        harness.ensure(outsiderKey, 5, false);
    }
}

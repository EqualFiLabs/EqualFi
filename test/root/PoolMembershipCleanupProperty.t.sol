// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    PoolMembershipRequired,
    CannotClearMembership
} from "../../src/libraries/Errors.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract MembershipStateHarness {
    function ensure(bytes32 positionKey, uint256 pid, bool allowAutoJoin) external returns (bool) {
        return LibPoolMembership._ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }

    function cleanup(bytes32 positionKey, uint256 pid) external {
        (bool canClear, string memory reason) = LibPoolMembership.canClearMembership(positionKey, pid);
        LibPoolMembership._leavePool(positionKey, pid, canClear, reason);
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function setPrincipal(bytes32 positionKey, uint256 pid, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = amount;
        p.totalDeposits = amount;
        p.trackedBalance = amount;
    }

    function setFixedLoanCount(bytes32 positionKey, uint256 pid, uint256 count) external {
        LibAppStorage.s().pools[pid].activeFixedLoanCount[positionKey] = count;
    }

    function setRollingLoan(bytes32 positionKey, uint256 pid, bool active, uint256 principal) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.active = active;
        loan.principalRemaining = principal;
    }

    function setDirectLocked(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
    }

    function setDirectBorrowed(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid] = amount;
    }

    function setDirectLent(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLent = amount;
    }
}

/// @notice Feature: multi-pool-position-nfts, Property 10: Membership Cleanup Safety
/// @notice Validates: Requirements 1.4, 7.5
contract MembershipCleanupSafetyPropertyTest is Test {
    MembershipStateHarness internal harness;
    bytes32 internal positionKey = keccak256("POSITION_A11CE");
    uint256 internal constant POOL_ID = 1;

    function setUp() public {
        harness = new MembershipStateHarness();
        harness.ensure(positionKey, POOL_ID, true);
    }

    function testProperty_MembershipCleanupSafety() public {
        harness.setPrincipal(positionKey, POOL_ID, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(CannotClearMembership.selector, positionKey, POOL_ID, "principal>0"));
        harness.cleanup(positionKey, POOL_ID);

        harness.setPrincipal(positionKey, POOL_ID, 0);
        harness.setFixedLoanCount(positionKey, POOL_ID, 0);
        harness.setRollingLoan(positionKey, POOL_ID, false, 0);
        harness.setDirectLocked(positionKey, POOL_ID, 0);
        harness.setDirectBorrowed(positionKey, POOL_ID, 0);
        harness.setDirectLent(positionKey, POOL_ID, 0);

        harness.cleanup(positionKey, POOL_ID);
        assertFalse(harness.isMember(positionKey, POOL_ID), "membership cleared when safe");
    }
}

/// @notice Feature: multi-pool-position-nfts, Property 11: Validation Error Clarity
/// @notice Validates: Requirements 7.2
contract MembershipValidationErrorClarityPropertyTest is Test {
    MembershipStateHarness internal harness;
    bytes32 internal positionKey = keccak256("POSITION_B0B");
    uint256 internal constant POOL_ID = 2;

    function setUp() public {
        harness = new MembershipStateHarness();
    }

    function testProperty_MembershipValidationErrors() public {
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, positionKey, POOL_ID));
        harness.cleanup(positionKey, POOL_ID);

        harness.ensure(positionKey, POOL_ID, true);
        harness.setDirectLocked(positionKey, POOL_ID, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                CannotClearMembership.selector, positionKey, POOL_ID, "locked direct principal"
            )
        );
        harness.cleanup(positionKey, POOL_ID);
    }
}

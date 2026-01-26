// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ActiveCreditViewFacet} from "../../src/views/ActiveCreditViewFacet.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {IActiveCreditViewFacet} from "../../src/interfaces/IActiveCreditViewFacet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ActiveCreditViewHarness is ActiveCreditViewFacet {
    function seedPool(
        uint256 pid,
        address underlying,
        uint256 index,
        uint256 remainder,
        uint256 activePrincipalTotal
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.activeCreditIndex = index;
        p.activeCreditIndexRemainder = remainder;
        p.activeCreditPrincipalTotal = activePrincipalTotal;
    }

    function seedState(
        uint256 pid,
        bytes32 user,
        uint256 encumbrancePrincipal,
        uint40 encumbranceStart,
        uint256 debtPrincipal,
        uint40 debtStart,
        uint256 snapshot
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
        Types.ActiveCreditState storage debt = p.userActiveCreditStateDebt[user];
        enc.principal = encumbrancePrincipal;
        enc.startTime = encumbranceStart;
        enc.indexSnapshot = snapshot;
        debt.principal = debtPrincipal;
        debt.startTime = debtStart;
        debt.indexSnapshot = snapshot;
    }
}

contract ActiveCreditViewFacetTest is Test {
    ActiveCreditViewHarness internal harness;
    bytes32 internal user = keccak256("userA11CE");
    uint256 internal constant PID = 7;

    function setUp() public {
        harness = new ActiveCreditViewHarness();
        vm.warp(5 days);
    }

    function test_activeCreditViewsProvideStateAndEligibility() public {
        uint256 index = 2e18;
        harness.seedPool(PID, address(1), index, 11, 0);
        harness.seedState(
            PID,
            user,
            1_000 ether,
            uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE),
            500 ether,
            uint40(block.timestamp - 12 hours),
            1e18
        );

        (Types.ActiveCreditState memory enc, Types.ActiveCreditState memory debt) = harness.getActiveCreditStates(PID, user);
        assertEq(enc.principal, 1_000 ether, "encumbrance principal");
        assertEq(debt.principal, 500 ether, "debt principal");

        IActiveCreditViewFacet.ActiveCreditStatus memory status = harness.getActiveCreditStatus(PID, user);
        assertTrue(status.encumbranceMature, "encumbrance mature");
        assertFalse(status.debtMature, "debt not mature");
        assertEq(status.encumbranceActiveWeight, 1_000 ether, "encumbrance weight");
        assertEq(status.debtActiveWeight, 0, "debt weight gated");

        uint256 pending = harness.pendingActiveCredit(PID, user);
        uint256 expected = Math.mulDiv(enc.principal, index - enc.indexSnapshot, LibActiveCreditIndex.INDEX_SCALE);
        assertEq(pending, expected, "pending active credit");

        (uint256 idx, uint256 rem, uint256 activeTotal) = harness.getActiveCreditIndex(PID);
        assertEq(idx, index, "index value");
        assertEq(rem, 11, "remainder");
        assertEq(activeTotal, 0, "active principal total passthrough");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FeeIndexInvariantHarness} from "../root/FeeIndexInvariants.t.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeIndexStatefulHandler is Test {
    FeeIndexInvariantHarness internal harness;
    uint256 internal pid;
    bytes32[] internal users;

    uint256 public totalFeesAccrued;
    uint256 public lastFeeIndex;

    constructor(FeeIndexInvariantHarness harness_, uint256 pid_, bytes32[] memory users_) {
        harness = harness_;
        pid = pid_;
        for (uint256 i = 0; i < users_.length; i++) {
            users.push(users_[i]);
        }
        lastFeeIndex = harness.getFeeIndex(pid);
    }

    function accrueFee(uint256 amountSeed) external {
        _snapshotFeeIndex();
        uint256 amount = bound(amountSeed, 1, 100 ether);
        harness.accrueFee(pid, amount);
        totalFeesAccrued += amount;
    }

    function settleUser(uint256 userSeed) external {
        _snapshotFeeIndex();
        bytes32 user = users[userSeed % users.length];
        harness.settleUser(pid, user);
    }

    function _snapshotFeeIndex() internal {
        lastFeeIndex = harness.getFeeIndex(pid);
    }
}

contract FeeIndexStatefulInvariantTest is StdInvariant, Test {
    FeeIndexInvariantHarness internal harness;
    FeeIndexStatefulHandler internal handler;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    uint256 internal constant SCALE = 1e18;

    bytes32 internal constant USER_A = keccak256("userA");
    bytes32 internal constant USER_B = keccak256("userB");
    bytes32 internal constant USER_C = keccak256("userC");

    function setUp() public {
        harness = new FeeIndexInvariantHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        harness.initPool(PID, address(token), 1_000 ether);
        harness.addUser(PID, USER_A, 500 ether);
        harness.addUser(PID, USER_B, 300 ether);
        harness.addUser(PID, USER_C, 200 ether);

        bytes32[] memory users = new bytes32[](3);
        users[0] = USER_A;
        users[1] = USER_B;
        users[2] = USER_C;

        handler = new FeeIndexStatefulHandler(harness, PID, users);
        targetContract(address(handler));
    }

    function invariant_feeIndexMonotonic() public {
        uint256 current = harness.getFeeIndex(PID);
        assertGe(current, handler.lastFeeIndex());
    }

    function invariant_noYieldFabrication() public {
        uint256 yieldA = harness.getUserAccruedYield(PID, USER_A);
        uint256 yieldB = harness.getUserAccruedYield(PID, USER_B);
        uint256 yieldC = harness.getUserAccruedYield(PID, USER_C);
        uint256 remainder = harness.getRemainderForPool(PID) / SCALE;

        uint256 distributed = yieldA + yieldB + yieldC + remainder;
        assertLe(distributed, handler.totalFeesAccrued() + 1);
    }
    
}

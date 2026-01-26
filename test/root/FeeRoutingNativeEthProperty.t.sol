// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibActionFees} from "../../src/libraries/LibActionFees.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeTreasury} from "../../src/libraries/LibFeeTreasury.sol";
import {Types} from "../../src/libraries/Types.sol";

contract FeeRoutingNativeHarness {
    function initPool(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = address(0);
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
    }

    function setUserPrincipal(uint256 pid, bytes32 key, uint256 amount) external {
        LibAppStorage.s().pools[pid].userPrincipal[key] = amount;
    }

    function setActionFee(uint256 pid, bytes32 action, uint128 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.actionFees[action] = Types.ActionFeeConfig(amount, true);
    }

    function setTreasury(address treasury, uint16 treasuryShareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareBps = treasuryShareBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = 0;
        store.activeCreditShareConfigured = true;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function chargeActionFee(uint256 pid, bytes32 action, bytes32 payer) external returns (uint256 feeAmount) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibActionFees.chargeFromUser(p, pid, action, payer);
    }

    function routePoolFee(uint256 pid, uint256 amount, bytes32 source)
        external
        returns (uint256 toTreasury, uint256 toActive, uint256 toIndex)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibFeeTreasury.accrueWithTreasury(p, pid, amount, source);
    }

    function poolState(uint256 pid, bytes32 key)
        external
        view
        returns (uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 userPrincipal)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        feeIndex = p.feeIndex;
        userPrincipal = p.userPrincipal[key];
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }
}

contract FeeRoutingNativeEthPropertyTest is Test {
    FeeRoutingNativeHarness internal harness;

    address internal treasury = address(0xBEEF);
    uint256 internal constant PID = 1;
    bytes32 internal constant ACTION = keccak256("ACTION_TEST");
    bytes32 internal constant PAYER = keccak256("PAYER");

    function setUp() public {
        harness = new FeeRoutingNativeHarness();
        harness.setTreasury(treasury, 2000);
    }

    /// Feature: native-eth-support, Property 11: Fee Routing Native ETH Correctness
    function test_nativeActionFeeRouting() public {
        uint256 totalDeposits = 100 ether;
        uint256 trackedBalance = 100 ether;
        uint256 feeAmount = 10 ether;
        harness.initPool(PID, totalDeposits, trackedBalance);
        harness.setUserPrincipal(PID, PAYER, totalDeposits);
        harness.setActionFee(PID, ACTION, uint128(feeAmount));
        harness.setNativeTrackedTotal(trackedBalance);

        vm.deal(address(harness), trackedBalance);
        uint256 treasuryBefore = treasury.balance;
        (,, uint256 feeIndexBefore,) = harness.poolState(PID, PAYER);

        uint256 charged = harness.chargeActionFee(PID, ACTION, PAYER);
        uint256 toTreasury = (feeAmount * 2000) / 10_000;
        uint256 toIndex = feeAmount - toTreasury;

        (uint256 totalAfter, uint256 trackedAfter, uint256 feeIndexAfter, uint256 principalAfter) =
            harness.poolState(PID, PAYER);

        assertEq(charged, feeAmount, "fee charged");
        assertEq(principalAfter, totalDeposits - feeAmount, "principal reduced");
        assertEq(totalAfter, totalDeposits - feeAmount, "total deposits reduced");
        assertEq(trackedAfter, trackedBalance - toTreasury, "tracked reduced by treasury share");
        assertEq(harness.nativeTrackedTotal(), trackedBalance - toTreasury, "native tracked reduced");
        assertEq(treasury.balance - treasuryBefore, toTreasury, "treasury received ETH");

        uint256 expectedDelta = (toIndex * 1e18) / (totalDeposits - feeAmount);
        assertEq(feeIndexAfter - feeIndexBefore, expectedDelta, "fee index accrued");
    }

    /// Feature: native-eth-support, Property 11: Fee Routing Native ETH Correctness
    function test_nativePoolFeeRouting() public {
        uint256 totalDeposits = 100 ether;
        uint256 trackedBalance = 110 ether;
        uint256 feeAmount = 5 ether;
        harness.initPool(PID, totalDeposits, trackedBalance);
        harness.setNativeTrackedTotal(trackedBalance);

        vm.deal(address(harness), trackedBalance);
        uint256 treasuryBefore = treasury.balance;
        uint256 feeIndexBefore = harness.feeIndex(PID);

        (uint256 toTreasury,, uint256 toIndex) = harness.routePoolFee(PID, feeAmount, keccak256("FLASH_FEE"));
        uint256 expectedTreasury = (feeAmount * 2000) / 10_000;
        assertEq(toTreasury, expectedTreasury, "treasury split");

        (, uint256 trackedAfter,,) = harness.poolState(PID, bytes32(0));

        assertEq(treasury.balance - treasuryBefore, expectedTreasury, "treasury received ETH");
        assertEq(trackedAfter, trackedBalance - expectedTreasury, "tracked reduced");
        assertEq(harness.nativeTrackedTotal(), trackedBalance - expectedTreasury, "native tracked reduced");

        uint256 expectedDelta = (toIndex * 1e18) / totalDeposits;
        assertEq(harness.feeIndex(PID) - feeIndexBefore, expectedDelta, "fee index accrued");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolSystemShareTreasuryFallbackHarness {
    function initPools(address underlying) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.assetToPoolId[underlying] = 1;

        Types.PoolData storage basePool = store.pools[1];
        basePool.initialized = true;
        basePool.underlying = underlying;

        Types.PoolData storage managedPool = store.pools[2];
        managedPool.initialized = true;
        managedPool.underlying = underlying;
        managedPool.isManagedPool = true;
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPoolBalances(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
    }

    function getPoolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getPoolFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function getPoolActiveCreditIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndex;
    }

    function routeManagedShare(uint256 pid, uint256 amount) external {
        LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), true, 0);
    }
}

contract ManagedPoolSystemShareTreasuryFallbackTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;

    ManagedPoolSystemShareTreasuryFallbackHarness private harness;
    MockERC20 private token;

    function setUp() public {
        harness = new ManagedPoolSystemShareTreasuryFallbackHarness();
        token = new MockERC20("Test Token", "TEST", 18, 0);

        harness.initPools(address(token));
        harness.setManagedPoolSystemShareBps(2000);
        harness.setTreasury(address(0xBEEF));

        token.mint(address(harness), 1_000_000 ether);
        harness.setPoolBalances(BASE_PID, 0, 500 ether); // zero deposits triggers fallback
        harness.setPoolBalances(MANAGED_PID, 1000 ether, 1100 ether);
    }

    function testTreasuryFallbackWhenBasePoolEmpty() public {
        uint256 amount = 100 ether;
        uint256 treasuryBefore = token.balanceOf(address(0xBEEF));
        uint256 baseTrackedBefore = harness.getPoolTrackedBalance(BASE_PID);
        uint256 baseFeeIndexBefore = harness.getPoolFeeIndex(BASE_PID);
        uint256 baseActiveBefore = harness.getPoolActiveCreditIndex(BASE_PID);

        harness.routeManagedShare(MANAGED_PID, amount);

        uint256 systemShare = (amount * 2000) / 10_000;
        uint256 managedShare = amount - systemShare;
        uint256 treasuryShare = (managedShare * 2000) / 10_000;
        uint256 treasuryAfter = token.balanceOf(address(0xBEEF));

        assertEq(
            treasuryAfter - treasuryBefore,
            systemShare + treasuryShare,
            "treasury should receive system + treasury share"
        );
        assertEq(harness.getPoolTrackedBalance(BASE_PID), baseTrackedBefore, "base trackedBalance unchanged");
        assertEq(harness.getPoolFeeIndex(BASE_PID), baseFeeIndexBefore, "base feeIndex unchanged");
        assertEq(harness.getPoolActiveCreditIndex(BASE_PID), baseActiveBefore, "base activeCreditIndex unchanged");
    }
}

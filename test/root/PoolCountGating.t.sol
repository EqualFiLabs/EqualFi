// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Tests that poolCount is properly maintained and FeeFacet validation works
contract PoolCountGatingTest is Test {
    PoolCountHarness internal harness;
    AdminGovernanceFacet internal admin;
    MockERC20 internal token1;
    MockERC20 internal token2;
    MockERC20 internal token3;
    
    address internal owner = address(this);

    function setUp() public {
        harness = new PoolCountHarness();
        admin = new AdminGovernanceFacet();
        token1 = new MockERC20("Mock Token", "MOCK", 18, 0);
        token2 = new MockERC20("Mock Token", "MOCK", 18, 0);
        token3 = new MockERC20("Mock Token", "MOCK", 18, 0);
        
        // Set owner
        harness.setOwner(owner);
    }

    /// @notice Test that poolCount increments when pools are initialized
    function test_PoolCount_IncrementsOnInit() public {
        assertEq(harness.getPoolCount(), 0, "Initial poolCount is 0");
        
        // Initialize pool 0
        harness.initPool(0, address(token1), false, 0);
        assertEq(harness.getPoolCount(), 1, "poolCount is 1 after first pool");
        
        // Initialize pool 1
        harness.initPool(1, address(token2), false, 0);
        assertEq(harness.getPoolCount(), 2, "poolCount is 2 after second pool");
        
        // Initialize pool 2
        harness.initPool(2, address(token3), false, 0);
        assertEq(harness.getPoolCount(), 3, "poolCount is 3 after third pool");
    }

    /// @notice Test that poolCount handles non-sequential pool IDs
    function test_PoolCount_HandlesNonSequential() public {
        // Initialize pool 5 first
        harness.initPool(5, address(token1), false, 0);
        assertEq(harness.getPoolCount(), 6, "poolCount is 6 (pid 5 + 1)");
        
        // Initialize pool 2 (lower than existing)
        harness.initPool(2, address(token2), false, 0);
        assertEq(harness.getPoolCount(), 6, "poolCount stays at 6");
        
        // Initialize pool 10 (higher)
        harness.initPool(10, address(token3), false, 0);
        assertEq(harness.getPoolCount(), 11, "poolCount is 11 (pid 10 + 1)");
    }

    /// @notice Test that action fee configuration works after multiple pools
    function test_ActionFee_WorksAfterMultiplePools() public {
        // Initialize 3 pools
        harness.initPool(0, address(token1), false, 0);
        harness.initPool(1, address(token2), false, 0);
        harness.initPool(2, address(token3), false, 0);
        
        assertEq(harness.getPoolCount(), 3, "Three pools initialized");
        
        // Should be able to set action fees on all pools
        bytes32 action = bytes32("deposit");
        
        harness.setPoolActionFee(0, action, 100, true);
        harness.setPoolActionFee(1, action, 200, true);
        harness.setPoolActionFee(2, action, 300, true);
        
        // Verify fees were set
        (uint128 amount0, bool enabled0) = harness.getActionFee(0, action);
        (uint128 amount1, bool enabled1) = harness.getActionFee(1, action);
        (uint128 amount2, bool enabled2) = harness.getActionFee(2, action);
        
        assertEq(amount0, 100, "Pool 0 fee set");
        assertTrue(enabled0, "Pool 0 enabled");
        
        assertEq(amount1, 200, "Pool 1 fee set");
        assertTrue(enabled1, "Pool 1 enabled");
        
        assertEq(amount2, 300, "Pool 2 fee set");
        assertTrue(enabled2, "Pool 2 enabled");
    }

    /// @notice Test that action fee config reverts for uninitialized pools
    function test_ActionFee_RevertsForUninitializedPool() public {
        // Initialize only pool 0
        harness.initPool(0, address(token1), false, 0);
        
        assertEq(harness.getPoolCount(), 1, "Only one pool");
        
        bytes32 action = bytes32("deposit");
        
        // Should work for pool 0
        harness.setPoolActionFee(0, action, 100, true);
        
        // Should revert for pool 1 (not initialized)
        vm.expectRevert();
        harness.setPoolActionFee(1, action, 100, true);
        
        // Should revert for pool 5 (way beyond count)
        vm.expectRevert();
        harness.setPoolActionFee(5, action, 100, true);
    }

    /// @notice Test preview action fee works with poolCount
    function test_PreviewActionFee_WorksWithPoolCount() public {
        harness.initPool(0, address(token1), false, 0);
        harness.initPool(1, address(token2), false, 0);
        
        bytes32 action = bytes32("deposit");
        harness.setPoolActionFee(0, action, 100, true);
        harness.setPoolActionFee(1, action, 200, true);
        
        // Preview should work for initialized pools
        uint256 fee0 = harness.previewActionFee(0, action);
        uint256 fee1 = harness.previewActionFee(1, action);
        
        assertEq(fee0, 100, "Pool 0 preview correct");
        assertEq(fee1, 200, "Pool 1 preview correct");
        
        // Preview should revert for uninitialized pool
        vm.expectRevert();
        harness.previewActionFee(2, action);
    }

    /// @notice Test that poolCount persists across multiple operations
    function test_PoolCount_PersistsAcrossOperations() public {
        // Initialize pools
        harness.initPool(0, address(token1), false, 0);
        uint256 count1 = harness.getPoolCount();
        
        // Do some operations
        harness.setPoolActionFee(0, bytes32("test"), 100, true);
        
        // Count should be unchanged
        assertEq(harness.getPoolCount(), count1, "Count unchanged after fee config");
        
        // Initialize another pool
        harness.initPool(1, address(token2), false, 0);
        uint256 count2 = harness.getPoolCount();
        
        assertGt(count2, count1, "Count increased");
        
        // More operations
        harness.setPoolActionFee(1, bytes32("test"), 200, true);
        
        // Count still unchanged
        assertEq(harness.getPoolCount(), count2, "Count unchanged after more ops");
    }

    /// @notice Test edge case: initialize pool with ID equal to current count
    function test_PoolCount_EdgeCaseEqualToCount() public {
        // Initialize pool 0
        harness.initPool(0, address(token1), false, 0);
        assertEq(harness.getPoolCount(), 1, "Count is 1");
        
        // Initialize pool 1 (equal to count)
        harness.initPool(1, address(token2), false, 0);
        assertEq(harness.getPoolCount(), 2, "Count is 2");
        
        // Initialize pool 2 (equal to count)
        harness.initPool(2, address(token3), false, 0);
        assertEq(harness.getPoolCount(), 3, "Count is 3");
    }

    /// @notice Test that large pool IDs work correctly
    function test_PoolCount_LargePoolIDs() public {
        // Initialize pool with large ID
        harness.initPool(100, address(token1), false, 0);
        assertEq(harness.getPoolCount(), 101, "Count is 101");
        
        // Can still configure it
        harness.setPoolActionFee(100, bytes32("test"), 100, true);
        
        // Can't configure pool 101 (not initialized)
        vm.expectRevert();
        harness.setPoolActionFee(101, bytes32("test"), 100, true);
    }
}

contract PoolCountHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function setOwner(address owner) external {
        s().timelock = owner;
    }

    function initPool(uint256 pid, address underlying, bool isCapped, uint256 depositCap) external {
        LibAppStorage.AppStorage storage store = s();
        Types.PoolData storage p = store.pools[pid];
        require(!p.initialized, "Pool exists");

        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.isCapped = isCapped;
        p.poolConfig.depositCap = depositCap;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        
        // Increment poolCount (mimics the fix)
        if (pid >= store.poolCount) {
            store.poolCount = pid + 1;
        }
    }

    function getPoolCount() external view returns (uint256) {
        return s().poolCount;
    }

    function setPoolActionFee(uint256 pid, bytes32 action, uint128 amount, bool enabled) external {
        LibAppStorage.AppStorage storage store = s();
        
        // Validate pool exists (mimics FeeFacet validation)
        require(pid < store.poolCount, "Pool not initialized");
        
        Types.PoolData storage pool = store.pools[pid];
        pool.actionFees[action].amount = amount;
        pool.actionFees[action].enabled = enabled;
    }

    function getActionFee(uint256 pid, bytes32 action) external view returns (uint128 amount, bool enabled) {
        Types.ActionFeeConfig storage config = s().pools[pid].actionFees[action];
        return (config.amount, config.enabled);
    }

    function previewActionFee(uint256 pid, bytes32 action) external view returns (uint256) {
        LibAppStorage.AppStorage storage store = s();
        
        // Validate pool exists
        require(pid < store.poolCount, "Pool not initialized");
        
        Types.ActionFeeConfig storage config = store.pools[pid].actionFees[action];
        return config.enabled ? config.amount : 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "../../src/libraries/Errors.sol";

/// @notice Helper contract for testing AUM fee management
contract AumFeeHelper is PoolManagementFacet, AdminGovernanceFacet {
    function getPoolConfig(uint256 pid) external view returns (Types.PoolConfig memory) {
        return s().pools[pid].poolConfig;
    }
    
    function getCurrentAumFeeBps(uint256 pid) external view returns (uint16) {
        return s().pools[pid].currentAumFeeBps;
    }
}

/// @notice Unit tests for AUM fee management edge cases
contract AumFeeManagementTest is Test {
    AumFeeHelper public helper;
    MockERC20 public token;
    
    uint256 constant PID = 1;
    address constant TIMELOCK = address(0x1234);
    address constant NON_ADMIN = address(0x5678);
    
    function setUp() public {
        helper = new AumFeeHelper();
        token = new MockERC20("Test Token", "TEST", 18, 1000000 ether);
        
        // Set owner and timelock in storage
        bytes32 appSlot = keccak256("equal.lend.app.storage");
        bytes32 diamondSlot = keccak256("diamond.standard.diamond.storage");
        uint256 ownerSlot = uint256(diamondSlot) + 3;
        vm.store(address(helper), bytes32(ownerSlot), bytes32(uint256(uint160(TIMELOCK))));
        
        uint256 timelockSlot = uint256(appSlot) + 8;
        vm.store(address(helper), bytes32(timelockSlot), bytes32(uint256(uint160(TIMELOCK))));
        
        // Set treasury
        vm.prank(TIMELOCK);
        helper.setTreasury(address(this));
        
        // Initialize pool with AUM bounds: min=100 (1%), max=500 (5%)
        Types.PoolConfig memory config;
        config.minDepositAmount = 1 ether;
        config.minLoanAmount = 0.1 ether;
        config.isCapped = false;
        config.depositCap = 0;
        config.aumFeeMinBps = 100; // 1%
        config.aumFeeMaxBps = 500; // 5%
        config.depositorLTVBps = 8000;
        
        vm.prank(TIMELOCK);
        helper.initPool(PID, address(token), config);
    }
    
    /// @notice Test setting fee at minimum bound
    function test_SetAumFee_AtMinimumBound() public {
        uint16 minBps = 100;
        
        vm.prank(TIMELOCK);
        helper.setAumFee(PID, minBps);
        
        assertEq(helper.getCurrentAumFeeBps(PID), minBps, "Fee should be set to minimum");
    }
    
    /// @notice Test setting fee at maximum bound
    function test_SetAumFee_AtMaximumBound() public {
        uint16 maxBps = 500;
        
        vm.prank(TIMELOCK);
        helper.setAumFee(PID, maxBps);
        
        assertEq(helper.getCurrentAumFeeBps(PID), maxBps, "Fee should be set to maximum");
    }
    
    /// @notice Test setting fee below minimum (should fail)
    function test_SetAumFee_BelowMinimum_Reverts() public {
        uint16 belowMin = 99;
        uint16 minBps = 100;
        uint16 maxBps = 500;
        
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AumFeeOutOfBounds.selector,
                belowMin,
                minBps,
                maxBps
            )
        );
        helper.setAumFee(PID, belowMin);
    }
    
    /// @notice Test setting fee above maximum (should fail)
    function test_SetAumFee_AboveMaximum_Reverts() public {
        uint16 aboveMax = 501;
        uint16 minBps = 100;
        uint16 maxBps = 500;
        
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AumFeeOutOfBounds.selector,
                aboveMax,
                minBps,
                maxBps
            )
        );
        helper.setAumFee(PID, aboveMax);
    }
    
    /// @notice Test non-admin caller (should fail)
    function test_SetAumFee_NonAdmin_Reverts() public {
        uint16 validFee = 300;
        
        vm.prank(NON_ADMIN);
        vm.expectRevert(); // LibAccess.enforceOwnerOrTimelock() will revert
        helper.setAumFee(PID, validFee);
    }
    
    /// @notice Test setting fee within bounds multiple times
    function test_SetAumFee_MultipleTimes() public {
        uint16 fee1 = 200;
        uint16 fee2 = 300;
        uint16 fee3 = 400;
        
        vm.startPrank(TIMELOCK);
        
        helper.setAumFee(PID, fee1);
        assertEq(helper.getCurrentAumFeeBps(PID), fee1, "Fee should be set to fee1");
        
        helper.setAumFee(PID, fee2);
        assertEq(helper.getCurrentAumFeeBps(PID), fee2, "Fee should be set to fee2");
        
        helper.setAumFee(PID, fee3);
        assertEq(helper.getCurrentAumFeeBps(PID), fee3, "Fee should be set to fee3");
        
        vm.stopPrank();
    }
    
    /// @notice Test event emission on fee update
    function test_SetAumFee_EmitsEvent() public {
        uint16 oldFee = helper.getCurrentAumFeeBps(PID);
        uint16 newFee = 300;
        
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(PID, oldFee, newFee);
        
        vm.prank(TIMELOCK);
        helper.setAumFee(PID, newFee);
    }
    
    /// @notice Test setting fee on non-existent pool (should fail)
    function test_SetAumFee_NonExistentPool_Reverts() public {
        uint256 nonExistentPid = 999;
        uint16 validFee = 300;
        
        vm.prank(TIMELOCK);
        vm.expectRevert("EqualFi: pool not initialized");
        helper.setAumFee(nonExistentPid, validFee);
    }
    
    /// @notice Test that immutable bounds cannot be changed
    function test_AumFeeBounds_AreImmutable() public {
        Types.PoolConfig memory config = helper.getPoolConfig(PID);
        
        uint16 initialMin = config.aumFeeMinBps;
        uint16 initialMax = config.aumFeeMaxBps;
        
        // Set fee multiple times
        vm.startPrank(TIMELOCK);
        helper.setAumFee(PID, 200);
        helper.setAumFee(PID, 300);
        helper.setAumFee(PID, 400);
        vm.stopPrank();
        
        // Verify bounds haven't changed
        config = helper.getPoolConfig(PID);
        assertEq(config.aumFeeMinBps, initialMin, "Min bound should remain unchanged");
        assertEq(config.aumFeeMaxBps, initialMax, "Max bound should remain unchanged");
    }
    
    /// @notice Test zero bounds (min=0, max=0)
    function test_SetAumFee_ZeroBounds() public {
        uint256 testPid = 2;
        
        Types.PoolConfig memory config;
        config.minDepositAmount = 1 ether;
        config.minLoanAmount = 0.1 ether;
        config.isCapped = false;
        config.depositCap = 0;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 0;
        config.depositorLTVBps = 8000;
        
        vm.prank(TIMELOCK);
        helper.initPool(testPid, address(token), config);
        
        // Should only be able to set fee to 0
        vm.prank(TIMELOCK);
        helper.setAumFee(testPid, 0);
        assertEq(helper.getCurrentAumFeeBps(testPid), 0, "Fee should be 0");
        
        // Any non-zero value should fail
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AumFeeOutOfBounds.selector,
                uint16(1),
                uint16(0),
                uint16(0)
            )
        );
        helper.setAumFee(testPid, 1);
    }
    
    /// @notice Test maximum bounds (min=10000, max=10000) - 100%
    function test_SetAumFee_MaximumBounds() public {
        uint256 testPid = 3;
        
        Types.PoolConfig memory config;
        config.minDepositAmount = 1 ether;
        config.minLoanAmount = 0.1 ether;
        config.isCapped = false;
        config.depositCap = 0;
        config.aumFeeMinBps = 10_000;
        config.aumFeeMaxBps = 10_000;
        config.depositorLTVBps = 8000;
        
        vm.prank(TIMELOCK);
        helper.initPool(testPid, address(token), config);
        
        // Should only be able to set fee to 10000
        vm.prank(TIMELOCK);
        helper.setAumFee(testPid, 10_000);
        assertEq(helper.getCurrentAumFeeBps(testPid), 10_000, "Fee should be 10000");
    }
}

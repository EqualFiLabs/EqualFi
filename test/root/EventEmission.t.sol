// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import "../../src/libraries/Errors.sol";

/// @title EventEmissionTest
/// @notice Comprehensive tests for event emission in AdminGovernanceFacet
/// @dev Task 13.1: Write unit tests for event emission
contract AdminGovernancePoolHarness is PoolManagementFacet, AdminGovernanceFacet {}

contract EventEmissionTest is Test {
    AdminGovernancePoolHarness internal facet;
    
    uint256 internal constant PID = 1;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address payable internal constant TREASURY = payable(address(0xFEE));
    address internal constant PERMISSIONLESS = address(0xCAFE);
    address internal constant UNDERLYING = address(0x1234);

    function setUp() public {
        facet = new AdminGovernancePoolHarness();
        bytes32 appSlot = keccak256("equal.lend.app.storage");

        // Set owner and timelock in facet storage via vm.store
        bytes32 diamondSlot = keccak256("diamond.standard.diamond.storage");
        uint256 ownerSlot = uint256(diamondSlot) + 3;
        vm.store(address(facet), bytes32(ownerSlot), bytes32(uint256(uint160(TIMELOCK))));
        uint256 timelockSlot = uint256(appSlot) + 8;
        vm.store(address(facet), bytes32(timelockSlot), bytes32(uint256(uint160(TIMELOCK))));

        vm.prank(TIMELOCK);
        facet.setTreasury(TREASURY);
    }

    function _createBasicConfig() internal pure returns (Types.PoolConfig memory) {
        Types.PoolConfig memory config;
        config.minDepositAmount = 1e6;
        config.minLoanAmount = 1e6;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 500;
        config.depositorLTVBps = 8000;
        return config;
    }

    function _createFullConfig() internal pure returns (Types.PoolConfig memory) {
        Types.PoolConfig memory config;
        config.rollingApyBps = 500; // 5%
        config.depositorLTVBps = 8000; // 80%
        config.maintenanceRateBps = 50; // 0.5%
        config.flashLoanFeeBps = 9; // 0.09%
        config.flashLoanAntiSplit = true;
        config.minDepositAmount = 1e6;
        config.minLoanAmount = 5e5;
        config.minTopupAmount = 1e5;
        config.isCapped = true;
        config.depositCap = 1_000_000e18;
        config.maxUserCount = 10000;
        config.aumFeeMinBps = 10; // 0.1%
        config.aumFeeMaxBps = 500; // 5%
        
        // Add fixed term configs
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](2);
        fixedTerms[0] = Types.FixedTermConfig({
            durationSecs: 30 days,
            apyBps: 400
        });
        fixedTerms[1] = Types.FixedTermConfig({
            durationSecs: 90 days,
            apyBps: 600
        });
        config.fixedTermConfigs = fixedTerms;
        
        return config;
    }

    // ============ PoolInitialized Event Tests ============

    /// @notice Test PoolInitialized event is emitted with correct parameters
    function testEvent_PoolInitialized_BasicConfig() public {
        Types.PoolConfig memory config = _createBasicConfig();
        
        // Expect the event with all parameters
        vm.expectEmit(true, true, false, true);
        emit PoolManagementFacet.PoolInitialized(PID, UNDERLYING, config);
        
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
    }

    /// @notice Test PoolInitialized event is emitted with full configuration
    function testEvent_PoolInitialized_FullConfig() public {
        Types.PoolConfig memory config = _createFullConfig();
        
        // Expect the event with all parameters
        vm.expectEmit(true, true, false, true);
        emit PoolManagementFacet.PoolInitialized(PID, UNDERLYING, config);
        
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
    }

    /// @notice Test PoolInitialized event contains all immutable parameters
    function testEvent_PoolInitialized_ContainsAllParameters() public {
        Types.PoolConfig memory config = _createFullConfig();
        
        // Record logs
        vm.recordLogs();
        
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // Get the emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the PoolInitialized event - use the actual event topic hash
        bytes32 poolInitializedTopic = keccak256(
            "PoolInitialized(uint256,address,(uint16,uint16,uint16,uint16,bool,uint256,uint256,uint256,bool,uint256,uint256,uint16,uint16,(uint40,uint16)[],(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool)))"
        );
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == poolInitializedTopic) {
                foundEvent = true;
                
                // Verify indexed parameters
                assertEq(uint256(logs[i].topics[1]), PID, "Event should contain correct PID");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), UNDERLYING, "Event should contain correct underlying");
                
                // Decode the config from event data
                Types.PoolConfig memory emittedConfig = abi.decode(logs[i].data, (Types.PoolConfig));
                
                // Verify all config parameters
                assertEq(emittedConfig.rollingApyBps, config.rollingApyBps, "rollingApyBps mismatch");
                assertEq(emittedConfig.depositorLTVBps, config.depositorLTVBps, "depositorLTVBps mismatch");
                assertEq(emittedConfig.maintenanceRateBps, config.maintenanceRateBps, "maintenanceRateBps mismatch");
                assertEq(emittedConfig.flashLoanFeeBps, config.flashLoanFeeBps, "flashLoanFeeBps mismatch");
                assertEq(emittedConfig.flashLoanAntiSplit, config.flashLoanAntiSplit, "flashLoanAntiSplit mismatch");
                assertEq(emittedConfig.minDepositAmount, config.minDepositAmount, "minDepositAmount mismatch");
                assertEq(emittedConfig.minLoanAmount, config.minLoanAmount, "minLoanAmount mismatch");
                assertEq(emittedConfig.minTopupAmount, config.minTopupAmount, "minTopupAmount mismatch");
                assertEq(emittedConfig.isCapped, config.isCapped, "isCapped mismatch");
                assertEq(emittedConfig.depositCap, config.depositCap, "depositCap mismatch");
                assertEq(emittedConfig.maxUserCount, config.maxUserCount, "maxUserCount mismatch");
                assertEq(emittedConfig.aumFeeMinBps, config.aumFeeMinBps, "aumFeeMinBps mismatch");
                assertEq(emittedConfig.aumFeeMaxBps, config.aumFeeMaxBps, "aumFeeMaxBps mismatch");
                assertEq(emittedConfig.fixedTermConfigs.length, config.fixedTermConfigs.length, "fixedTermConfigs length mismatch");
                
                break;
            }
        }
        
        assertTrue(foundEvent, "PoolInitialized event should be emitted");
    }

    /// @notice Test PoolInitialized event is emitted for permissionless creation
    function testEvent_PoolInitialized_PermissionlessCreation() public {
        // Set pool creation fee
        vm.prank(TIMELOCK);
        facet.setPoolCreationFee(1 ether);

        Types.PoolConfig memory config = _createFullConfig();
        vm.prank(TIMELOCK);
        facet.setDefaultPoolConfig(config);
        
        // Give permissionless user ETH
        vm.deal(PERMISSIONLESS, 2 ether);
        
        // Expect the event
        vm.expectEmit(true, true, false, true);
        emit PoolManagementFacet.PoolInitialized(PID, UNDERLYING, config);
        
        vm.prank(PERMISSIONLESS);
        facet.initPool{value: 1 ether}(UNDERLYING);
    }

    /// @notice Test PoolInitialized event is properly indexed
    function testEvent_PoolInitialized_Indexing() public {
        Types.PoolConfig memory config = _createBasicConfig();
        
        vm.recordLogs();
        
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the PoolInitialized event - use the actual event topic hash
        bytes32 poolInitializedTopic = keccak256(
            "PoolInitialized(uint256,address,(uint16,uint16,uint16,uint16,bool,uint256,uint256,uint256,bool,uint256,uint256,uint16,uint16,(uint40,uint16)[],(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool)))"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == poolInitializedTopic) {
                // Verify we have 3 topics: event signature + 2 indexed parameters (pid, underlying)
                assertEq(logs[i].topics.length, 3, "Should have 3 topics (signature + 2 indexed params)");
                break;
            }
        }
    }

    // ============ AumFeeUpdated Event Tests ============

    /// @notice Test AumFeeUpdated event is emitted with correct parameters
    function testEvent_AumFeeUpdated_BasicUpdate() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // Update AUM fee
        uint16 oldFee = 0; // Initial fee is aumFeeMinBps
        uint16 newFee = 250; // 2.5%
        
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(PID, oldFee, newFee);
        
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, newFee);
    }

    /// @notice Test AumFeeUpdated event with multiple updates
    function testEvent_AumFeeUpdated_MultipleUpdates() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // First update
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(PID, 0, 100);
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 100);
        
        // Second update
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(PID, 100, 250);
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 250);
        
        // Third update
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(PID, 250, 500);
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 500);
    }

    /// @notice Test AumFeeUpdated event contains correct old and new values
    function testEvent_AumFeeUpdated_CorrectValues() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        vm.recordLogs();
        
        // Update fee
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 300);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the AumFeeUpdated event
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("AumFeeUpdated(uint256,uint16,uint16)")) {
                foundEvent = true;
                
                // Verify indexed PID
                assertEq(uint256(logs[i].topics[1]), PID, "Event should contain correct PID");
                
                // Decode old and new fees
                (uint16 oldFee, uint16 newFee) = abi.decode(logs[i].data, (uint16, uint16));
                assertEq(oldFee, 0, "Old fee should be 0");
                assertEq(newFee, 300, "New fee should be 300");
                
                break;
            }
        }
        
        assertTrue(foundEvent, "AumFeeUpdated event should be emitted");
    }

    /// @notice Test AumFeeUpdated event is properly indexed
    function testEvent_AumFeeUpdated_Indexing() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        vm.recordLogs();
        
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 200);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the AumFeeUpdated event
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("AumFeeUpdated(uint256,uint16,uint16)")) {
                // Verify we have 2 topics: event signature + 1 indexed parameter (pid)
                assertEq(logs[i].topics.length, 2, "Should have 2 topics (signature + 1 indexed param)");
                break;
            }
        }
    }

    /// @notice Test AumFeeUpdated event for different pools
    function testEvent_AumFeeUpdated_MultiplePools() public {
        // Initialize multiple pools
        Types.PoolConfig memory config = _createBasicConfig();
        
        vm.prank(TIMELOCK);
        facet.initPool(1, address(0x1), config);
        
        vm.prank(TIMELOCK);
        facet.initPool(2, address(0x2), config);
        
        // Update fee for pool 1
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(1, 0, 100);
        vm.prank(TIMELOCK);
        facet.setAumFee(1, 100);
        
        // Update fee for pool 2
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.AumFeeUpdated(2, 0, 200);
        vm.prank(TIMELOCK);
        facet.setAumFee(2, 200);
    }

    // ============ PoolDeprecated Event Tests ============

    /// @notice Test PoolDeprecated event is emitted when setting to true
    function testEvent_PoolDeprecated_SetTrue() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // Set deprecated to true
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(PID, true);
        
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
    }

    /// @notice Test PoolDeprecated event is emitted when setting to false
    function testEvent_PoolDeprecated_SetFalse() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // First set to true
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
        
        // Then set to false
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(PID, false);
        
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, false);
    }

    /// @notice Test PoolDeprecated event contains correct parameters
    function testEvent_PoolDeprecated_CorrectParameters() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        vm.recordLogs();
        
        // Set deprecated
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the PoolDeprecated event
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PoolDeprecated(uint256,bool)")) {
                foundEvent = true;
                
                // Verify indexed PID
                assertEq(uint256(logs[i].topics[1]), PID, "Event should contain correct PID");
                
                // Decode deprecated flag
                bool deprecated = abi.decode(logs[i].data, (bool));
                assertTrue(deprecated, "Deprecated flag should be true");
                
                break;
            }
        }
        
        assertTrue(foundEvent, "PoolDeprecated event should be emitted");
    }

    /// @notice Test PoolDeprecated event is properly indexed
    function testEvent_PoolDeprecated_Indexing() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        vm.recordLogs();
        
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the PoolDeprecated event
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PoolDeprecated(uint256,bool)")) {
                // Verify we have 2 topics: event signature + 1 indexed parameter (pid)
                assertEq(logs[i].topics.length, 2, "Should have 2 topics (signature + 1 indexed param)");
                break;
            }
        }
    }

    /// @notice Test PoolDeprecated event for multiple pools
    function testEvent_PoolDeprecated_MultiplePools() public {
        // Initialize multiple pools
        Types.PoolConfig memory config = _createBasicConfig();
        
        vm.prank(TIMELOCK);
        facet.initPool(1, address(0x1), config);
        
        vm.prank(TIMELOCK);
        facet.initPool(2, address(0x2), config);
        
        // Deprecate pool 1
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(1, true);
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(1, true);
        
        // Deprecate pool 2
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(2, true);
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(2, true);
    }

    /// @notice Test PoolDeprecated event for toggle behavior
    function testEvent_PoolDeprecated_Toggle() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        // Toggle deprecated flag multiple times
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(PID, true);
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
        
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(PID, false);
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, false);
        
        vm.expectEmit(true, false, false, true);
        emit AdminGovernanceFacet.PoolDeprecated(PID, true);
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
    }

    // ============ Event Queryability Tests ============

    /// @notice Test that events can be queried off-chain by filtering on indexed parameters
    function testEvent_Queryability_ByPoolId() public {
        // Initialize multiple pools
        Types.PoolConfig memory config = _createBasicConfig();
        
        vm.prank(TIMELOCK);
        facet.initPool(1, address(0x1), config);
        
        vm.prank(TIMELOCK);
        facet.initPool(2, address(0x2), config);
        
        vm.prank(TIMELOCK);
        facet.initPool(3, address(0x3), config);
        
        vm.recordLogs();
        
        // Perform operations on different pools
        vm.prank(TIMELOCK);
        facet.setAumFee(1, 100);
        
        vm.prank(TIMELOCK);
        facet.setAumFee(2, 200);
        
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(1, true);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Count events for pool 1
        uint256 pool1Events = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && uint256(logs[i].topics[1]) == 1) {
                pool1Events++;
            }
        }
        
        // Pool 1 should have 2 events: AumFeeUpdated and PoolDeprecated
        assertEq(pool1Events, 2, "Pool 1 should have 2 events");
    }

    /// @notice Test that all events are emitted in correct order
    function testEvent_EmissionOrder() public {
        // Initialize pool
        Types.PoolConfig memory config = _createBasicConfig();
        
        vm.recordLogs();
        
        vm.prank(TIMELOCK);
        facet.initPool(PID, UNDERLYING, config);
        
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 100);
        
        vm.prank(TIMELOCK);
        facet.setPoolDeprecated(PID, true);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Verify events are in order: PoolInitialized, AumFeeUpdated, PoolDeprecated
        // Use actual event topic hashes
        bytes32 poolInitializedSig = keccak256(
            "PoolInitialized(uint256,address,(uint16,uint16,uint16,uint16,bool,uint256,uint256,uint256,bool,uint256,uint256,uint16,uint16,(uint40,uint16)[],(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool),(uint128,bool)))"
        );
        bytes32 aumFeeUpdatedSig = keccak256("AumFeeUpdated(uint256,uint16,uint16)");
        bytes32 poolDeprecatedSig = keccak256("PoolDeprecated(uint256,bool)");
        
        bool foundPoolInit = false;
        bool foundAumFee = false;
        bool foundDeprecated = false;
        
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == poolInitializedSig) {
                assertFalse(foundAumFee, "PoolInitialized should come before AumFeeUpdated");
                assertFalse(foundDeprecated, "PoolInitialized should come before PoolDeprecated");
                foundPoolInit = true;
            } else if (logs[i].topics[0] == aumFeeUpdatedSig) {
                assertTrue(foundPoolInit, "AumFeeUpdated should come after PoolInitialized");
                assertFalse(foundDeprecated, "AumFeeUpdated should come before PoolDeprecated");
                foundAumFee = true;
            } else if (logs[i].topics[0] == poolDeprecatedSig) {
                assertTrue(foundPoolInit, "PoolDeprecated should come after PoolInitialized");
                assertTrue(foundAumFee, "PoolDeprecated should come after AumFeeUpdated");
                foundDeprecated = true;
            }
        }
        
        assertTrue(foundPoolInit, "Should have found PoolInitialized event");
        assertTrue(foundAumFee, "Should have found AumFeeUpdated event");
        assertTrue(foundDeprecated, "Should have found PoolDeprecated event");
    }
}

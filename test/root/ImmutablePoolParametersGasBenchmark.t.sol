// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";

/// @notice Gas benchmarking tests for immutable pool parameters
/// @dev Measures gas costs for pool initialization, parameter queries, and AUM fee updates
contract ImmutablePoolParametersGasBenchmarkTest is Test {
    AdminGovernanceHarness facet;
    
    address constant TIMELOCK = address(0xBEEF);
    address payable constant TREASURY = payable(address(0xFEE));
    uint256 constant PID = 1;
    
    function setUp() public {
        facet = new AdminGovernanceHarness();
        
        // Set up storage slots for owner and timelock
        bytes32 appSlot = keccak256("equal.lend.app.storage");
        bytes32 diamondSlot = keccak256("diamond.standard.diamond.storage");
        uint256 ownerSlot = uint256(diamondSlot) + 3;
        vm.store(address(facet), bytes32(ownerSlot), bytes32(uint256(uint160(TIMELOCK))));
        uint256 timelockSlot = uint256(appSlot) + 8;
        vm.store(address(facet), bytes32(timelockSlot), bytes32(uint256(uint160(TIMELOCK))));
        
        // Set treasury
        vm.prank(TIMELOCK);
        facet.setTreasury(TREASURY);
    }
    
    function _createBasicConfig() internal pure returns (Types.PoolConfig memory) {
        Types.PoolConfig memory config;
        config.rollingApyBps = 500;
        config.depositorLTVBps = 8000;
        config.maintenanceRateBps = 100;
        config.flashLoanFeeBps = 9;
        config.flashLoanAntiSplit = true;
        config.minDepositAmount = 0.01 ether;
        config.minLoanAmount = 0.01 ether;
        config.minTopupAmount = 0.01 ether;
        config.isCapped = true;
        config.depositCap = 1000 ether;
        config.maxUserCount = 1000;
        config.aumFeeMinBps = 10;
        config.aumFeeMaxBps = 100;
        config.fixedTermConfigs = new Types.FixedTermConfig[](0);
        return config;
    }
    
    function _createConfigWithFixedTerms(uint256 numTerms) internal pure returns (Types.PoolConfig memory) {
        Types.PoolConfig memory config = _createBasicConfig();
        config.fixedTermConfigs = new Types.FixedTermConfig[](numTerms);
        for (uint256 i = 0; i < numTerms; i++) {
            config.fixedTermConfigs[i] = Types.FixedTermConfig({
                durationSecs: uint40(30 days * (i + 1)),
                apyBps: uint16(300 + i * 50)
            });
        }
        return config;
    }
    
    /// @notice Benchmark pool initialization with minimal config
    function test_GasBenchmark_PoolInitialization_Minimal() public {
        Types.PoolConfig memory config = _createBasicConfig();
        
        uint256 gasBefore = gasleft();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x1), config);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for pool initialization (minimal config):", gasUsed);
        
        // Verify pool was created
        assertEq(facet.getPoolUnderlying(PID), address(0x1));
    }
    
    /// @notice Benchmark pool initialization with 3 fixed term configs
    function test_GasBenchmark_PoolInitialization_With3FixedTerms() public {
        Types.PoolConfig memory config = _createConfigWithFixedTerms(3);
        
        uint256 gasBefore = gasleft();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x2), config);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for pool initialization (3 fixed terms):", gasUsed);
        
        // Verify fixed terms were stored
        Types.FixedTermConfig[] memory terms = facet.getFixedTermConfigs(PID);
        assertEq(terms.length, 3);
    }
    
    /// @notice Benchmark pool initialization with 5 fixed term configs
    function test_GasBenchmark_PoolInitialization_With5FixedTerms() public {
        Types.PoolConfig memory config = _createConfigWithFixedTerms(5);
        
        uint256 gasBefore = gasleft();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x3), config);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for pool initialization (5 fixed terms):", gasUsed);
        
        // Verify fixed terms were stored
        Types.FixedTermConfig[] memory terms = facet.getFixedTermConfigs(PID);
        assertEq(terms.length, 5);
    }
    
    /// @notice Benchmark getPoolConfig view function
    function test_GasBenchmark_GetImmutableConfig() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createConfigWithFixedTerms(3);
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x4), config);
        
        // Benchmark view call
        uint256 gasBefore = gasleft();
        Types.PoolConfig memory retrieved = facet.getPoolConfig(PID);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for getPoolConfig():", gasUsed);
        
        // Verify correctness
        assertEq(retrieved.rollingApyBps, config.rollingApyBps);
        assertEq(retrieved.fixedTermConfigs.length, 3);
    }
    
    /// @notice Benchmark getAumFeeInfo view function
    function test_GasBenchmark_GetAumFeeInfo() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x5), config);
        
        // Benchmark view call
        uint256 gasBefore = gasleft();
        (uint16 current, uint16 min, uint16 max) = facet.getAumFeeInfo(PID);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for getAumFeeInfo():", gasUsed);
        
        // Verify correctness
        assertEq(current, 10);
        assertEq(min, 10);
        assertEq(max, 100);
    }
    
    /// @notice Benchmark getPoolInfo comprehensive view function
    function test_GasBenchmark_GetPoolInfo() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createConfigWithFixedTerms(3);
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x6), config);
        
        // Benchmark view call
        uint256 gasBefore = gasleft();
        (
            address underlying,
            Types.PoolConfig memory retrieved,
            uint16 currentAumFee,
            uint256 totalDeposits,
            bool deprecated
        ) = facet.getPoolInfo(PID);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for getPoolInfo():", gasUsed);
        
        // Verify correctness
        assertEq(underlying, address(0x6));
        assertEq(retrieved.rollingApyBps, config.rollingApyBps);
        assertEq(currentAumFee, 10);
        assertEq(totalDeposits, 0);
        assertFalse(deprecated);
    }
    
    /// @notice Benchmark setAumFee function
    function test_GasBenchmark_SetAumFee() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x7), config);
        
        // Benchmark AUM fee update
        uint256 gasBefore = gasleft();
        vm.prank(TIMELOCK);
        facet.setAumFee(PID, 50);
        uint256 gasUsed = gasBefore - gasleft();
        
        console2.log("Gas used for setAumFee():", gasUsed);
        
        // Verify update
        (uint16 current,,) = facet.getAumFeeInfo(PID);
        assertEq(current, 50);
    }
    
    /// @notice Benchmark individual parameter queries
    function test_GasBenchmark_IndividualParameterQueries() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createBasicConfig();
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x8), config);
        
        // Benchmark getMinDepositAmount
        uint256 gasBefore = gasleft();
        uint256 minDeposit = facet.getMinDepositAmount(PID);
        uint256 gasUsed1 = gasBefore - gasleft();
        console2.log("Gas used for getMinDepositAmount():", gasUsed1);
        assertEq(minDeposit, 0.01 ether);
        
        // Benchmark getMinLoanAmount
        gasBefore = gasleft();
        uint256 minLoan = facet.getMinLoanAmount(PID);
        uint256 gasUsed2 = gasBefore - gasleft();
        console2.log("Gas used for getMinLoanAmount():", gasUsed2);
        assertEq(minLoan, 0.01 ether);
        
        // Benchmark getPoolCaps
        gasBefore = gasleft();
        (bool isCapped, uint256 cap) = facet.getPoolCaps(PID);
        uint256 gasUsed3 = gasBefore - gasleft();
        console2.log("Gas used for getPoolCaps():", gasUsed3);
        assertTrue(isCapped);
        assertEq(cap, 1000 ether);
        
        // Benchmark getFlashConfig
        gasBefore = gasleft();
        (uint16 feeBps, bool antiSplit) = facet.getFlashConfig(PID);
        uint256 gasUsed4 = gasBefore - gasleft();
        console2.log("Gas used for getFlashConfig():", gasUsed4);
        assertEq(feeBps, 9);
        assertTrue(antiSplit);
    }
    
    /// @notice Compare gas costs: multiple individual queries vs single comprehensive query
    function test_GasBenchmark_CompareQueryStrategies() public {
        // Initialize pool first
        Types.PoolConfig memory config = _createConfigWithFixedTerms(3);
        vm.prank(TIMELOCK);
        facet.initPool(PID, address(0x9), config);
        
        // Strategy 1: Multiple individual queries
        uint256 gasBefore = gasleft();
        uint256 minDeposit = facet.getMinDepositAmount(PID);
        uint256 minLoan = facet.getMinLoanAmount(PID);
        (bool isCapped, uint256 cap) = facet.getPoolCaps(PID);
        (uint16 feeBps, bool antiSplit) = facet.getFlashConfig(PID);
        (uint16 current, uint16 min, uint16 max) = facet.getAumFeeInfo(PID);
        uint256 gasIndividual = gasBefore - gasleft();
        
        console2.log("Gas used for 5 individual queries:", gasIndividual);
        
        // Strategy 2: Single comprehensive query
        gasBefore = gasleft();
        (
            address underlying,
            Types.PoolConfig memory retrieved,
            uint16 currentAumFee,
            uint256 totalDeposits,
            bool deprecated
        ) = facet.getPoolInfo(PID);
        uint256 gasComprehensive = gasBefore - gasleft();
        
        console2.log("Gas used for 1 comprehensive query:", gasComprehensive);
        console2.log("Gas savings:", gasIndividual > gasComprehensive ? gasIndividual - gasComprehensive : 0);
        
        // Verify both strategies return same data
        assertEq(minDeposit, retrieved.minDepositAmount);
        assertEq(minLoan, retrieved.minLoanAmount);
        assertEq(isCapped, retrieved.isCapped);
        assertEq(cap, retrieved.depositCap);
        assertEq(feeBps, retrieved.flashLoanFeeBps);
        assertEq(antiSplit, retrieved.flashLoanAntiSplit);
        assertEq(current, currentAumFee);
    }
}

/// @notice Harness combining AdminGovernanceFacet and ConfigViewFacet for benchmarking
contract AdminGovernanceHarness is PoolManagementFacet, AdminGovernanceFacet {
    function getPoolUnderlying(uint256 pid) external view returns (address) {
        return s().pools[pid].underlying;
    }
    
    // View functions from ConfigViewFacet
    function getPoolConfig(uint256 pid) external view returns (Types.PoolConfig memory config) {
        Types.PoolData storage p = _pool(pid);
        config = p.poolConfig;
    }
    
    function getAumFeeInfo(uint256 pid) 
        external 
        view 
        returns (
            uint16 currentFeeBps,
            uint16 minBps,
            uint16 maxBps
        ) 
    {
        Types.PoolData storage p = _pool(pid);
        currentFeeBps = p.currentAumFeeBps;
        minBps = p.poolConfig.aumFeeMinBps;
        maxBps = p.poolConfig.aumFeeMaxBps;
    }
    
    function getPoolInfo(uint256 pid) 
        external 
        view 
        returns (
            address underlying,
            Types.PoolConfig memory config,
            uint16 currentAumFeeBps,
            uint256 totalDeposits,
            bool deprecated
        ) 
    {
        Types.PoolData storage p = _pool(pid);
        underlying = p.underlying;
        config = p.poolConfig;
        currentAumFeeBps = p.currentAumFeeBps;
        totalDeposits = p.totalDeposits;
        deprecated = p.deprecated;
    }
    
    function getMinDepositAmount(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = _pool(pid);
        return p.poolConfig.minDepositAmount;
    }
    
    function getMinLoanAmount(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = _pool(pid);
        return p.poolConfig.minLoanAmount;
    }
    
    function getPoolCaps(uint256 pid) external view returns (bool isCapped, uint256 depositCap) {
        Types.PoolData storage p = _pool(pid);
        isCapped = p.poolConfig.isCapped;
        depositCap = p.poolConfig.depositCap;
    }
    
    function getFlashConfig(uint256 pid) external view returns (uint16 feeBps, bool antiSplit) {
        Types.PoolData storage p = _pool(pid);
        feeBps = p.poolConfig.flashLoanFeeBps;
        antiSplit = p.poolConfig.flashLoanAntiSplit;
    }
    
    function getFixedTermConfigs(uint256 pid) external view returns (Types.FixedTermConfig[] memory configs) {
        Types.PoolData storage p = _pool(pid);
        uint256 len = p.poolConfig.fixedTermConfigs.length;
        configs = new Types.FixedTermConfig[](len);
        for (uint256 i; i < len; i++) {
            configs[i] = p.poolConfig.fixedTermConfigs[i];
        }
    }
}

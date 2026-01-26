// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract ConfigViewHarness is ConfigViewFacet {
    function initPool(uint256 pid, address underlying, bool isCapped, uint256 depositCap) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.isCapped = isCapped;
        p.poolConfig.depositCap = depositCap;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        p.poolConfig.maintenanceRateBps = 100;
    }

    function setMaintenance(uint256 pid, uint16 rateBps, uint64 lastTimestamp, uint256 pending) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.poolConfig.maintenanceRateBps = rateBps;
        p.lastMaintenanceTimestamp = lastTimestamp;
        p.pendingMaintenance = pending;
    }

    function setMaintenanceGlobals(uint16 defaultRateBps, address receiver) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultMaintenanceRateBps = defaultRateBps;
        store.foundationReceiver = receiver;
    }

    function addFixedTermConfig(uint256 pid, Types.FixedTermConfig memory cfg) external {
        LibAppStorage.s().pools[pid].poolConfig.fixedTermConfigs.push(cfg);
    }

    function initPoolWithFullConfig(uint256 pid, address underlying, Types.PoolConfig memory config) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        
        // Store complete immutable configuration
        p.poolConfig.rollingApyBps = config.rollingApyBps;
        p.poolConfig.depositorLTVBps = config.depositorLTVBps;
        p.poolConfig.maintenanceRateBps = config.maintenanceRateBps;
        p.poolConfig.flashLoanFeeBps = config.flashLoanFeeBps;
        p.poolConfig.flashLoanAntiSplit = config.flashLoanAntiSplit;
        p.poolConfig.minDepositAmount = config.minDepositAmount;
        p.poolConfig.minLoanAmount = config.minLoanAmount;
        p.poolConfig.minTopupAmount = config.minTopupAmount;
        p.poolConfig.isCapped = config.isCapped;
        p.poolConfig.depositCap = config.depositCap;
        p.poolConfig.maxUserCount = config.maxUserCount;
        p.poolConfig.aumFeeMinBps = config.aumFeeMinBps;
        p.poolConfig.aumFeeMaxBps = config.aumFeeMaxBps;
        
        // Store fixed term configs
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            p.poolConfig.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        
        // Initialize operational state
        p.currentAumFeeBps = config.aumFeeMinBps;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        p.totalDeposits = 0;
        p.deprecated = false;
    }

    function setAumFee(uint256 pid, uint16 feeBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.currentAumFeeBps = feeBps;
    }

    function setDeprecated(uint256 pid, bool deprecated) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.deprecated = deprecated;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = amount;
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }
}

contract ConfigViewFacetTest is Test {
    ConfigViewHarness internal viewFacet;
    uint256 internal constant PID = 1;

    function setUp() public {
        viewFacet = new ConfigViewHarness();
    }

    function testPoolCapsExposeValues() public {
        viewFacet.initPool(PID, address(0xA11CE), true, 1_000 ether);

        (bool isCapped, uint256 depositCap) = viewFacet.getPoolCaps(PID);
        assertTrue(isCapped);
        assertEq(depositCap, 1_000 ether);
    }

    function testMaintenanceStateExposure() public {
        viewFacet.initPool(PID, address(0xBEEF), false, 0);
        viewFacet.setMaintenance(PID, 80, 12345, 2 ether);
        viewFacet.setMaintenanceGlobals(100, address(0xF00D));

        (uint16 poolRate, uint16 defaultRate, uint64 lastTs, uint256 pending, uint256 epochLength, address receiver) =
            viewFacet.getMaintenanceState(PID);

        assertEq(poolRate, 80);
        assertEq(defaultRate, 100);
        assertEq(lastTs, 12345);
        assertEq(pending, 2 ether);
        assertEq(epochLength, 1 days);
        assertEq(receiver, address(0xF00D));
    }

    function testGetPoolIdForAssetReturnsPool() public {
        address asset = address(0xABCD);
        viewFacet.setAssetToPoolId(asset, 7);
        assertEq(viewFacet.getPoolIdForAsset(asset), 7);
    }

    function testGetPoolIdForAssetRevertsWhenMissing() public {
        address asset = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(NoPoolForAsset.selector, asset));
        viewFacet.getPoolIdForAsset(asset);
    }

    function testGetFixedTermConfigsReturnsRates() public {
        viewFacet.initPool(PID, address(0xCAFE), false, 0);
        Types.FixedTermConfig memory cfg =
            Types.FixedTermConfig({durationSecs: 90 days, apyBps: 1200});
        viewFacet.addFixedTermConfig(PID, cfg);

        Types.FixedTermConfig[] memory returned = viewFacet.getFixedTermConfigs(PID);
        assertEq(returned.length, 1);
        assertEq(returned[0].durationSecs, cfg.durationSecs);
        assertEq(returned[0].apyBps, cfg.apyBps);
    }

    // ============ Tests for new view functions (Task 7.1) ============

    function testGetImmutableConfigReturnsCorrectValues() public {
        // Create a complete immutable config
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](2);
        fixedTerms[0] = Types.FixedTermConfig({
            durationSecs: 30 days,
            apyBps: 800
        });
        fixedTerms[1] = Types.FixedTermConfig({
            durationSecs: 90 days,
            apyBps: 1200
        });

        Types.PoolConfig memory config = Types.PoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 100,
            flashLoanFeeBps: 50,
            flashLoanAntiSplit: true,
            minDepositAmount: 1 ether,
            minLoanAmount: 0.5 ether,
            minTopupAmount: 0.1 ether,
            isCapped: true,
            depositCap: 1000 ether,
            maxUserCount: 100,
            aumFeeMinBps: 10,
            aumFeeMaxBps: 100,
            fixedTermConfigs: fixedTerms,
            borrowFee: Types.ActionFeeConfig(0, false),
            repayFee: Types.ActionFeeConfig(0, false),
            withdrawFee: Types.ActionFeeConfig(0, false),
            flashFee: Types.ActionFeeConfig(0, false),
            closeRollingFee: Types.ActionFeeConfig(0, false)
        });

        viewFacet.initPoolWithFullConfig(PID, address(0xDEAD), config);

        // Get immutable config and verify all fields
        Types.PoolConfig memory returned = viewFacet.getPoolConfig(PID);
        
        assertEq(returned.rollingApyBps, 500);
        assertEq(returned.depositorLTVBps, 8000);
        assertEq(returned.maintenanceRateBps, 100);
        assertEq(returned.flashLoanFeeBps, 50);
        assertTrue(returned.flashLoanAntiSplit);
        assertEq(returned.minDepositAmount, 1 ether);
        assertEq(returned.minLoanAmount, 0.5 ether);
        assertEq(returned.minTopupAmount, 0.1 ether);
        assertTrue(returned.isCapped);
        assertEq(returned.depositCap, 1000 ether);
        assertEq(returned.maxUserCount, 100);
        assertEq(returned.aumFeeMinBps, 10);
        assertEq(returned.aumFeeMaxBps, 100);
        assertEq(returned.fixedTermConfigs.length, 2);
        assertEq(returned.fixedTermConfigs[0].durationSecs, 30 days);
        assertEq(returned.fixedTermConfigs[0].apyBps, 800);
        assertEq(returned.fixedTermConfigs[1].durationSecs, 90 days);
        assertEq(returned.fixedTermConfigs[1].apyBps, 1200);
    }

    function testPoolConfigSummaryMatchesFullConfig() public {
        Types.PoolConfig memory config = Types.PoolConfig({
            rollingApyBps: 350,
            depositorLTVBps: 7200,
            maintenanceRateBps: 90,
            flashLoanFeeBps: 20,
            flashLoanAntiSplit: false,
            minDepositAmount: 2 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.2 ether,
            isCapped: true,
            depositCap: 500 ether,
            maxUserCount: 50,
            aumFeeMinBps: 5,
            aumFeeMaxBps: 50,
            fixedTermConfigs: new Types.FixedTermConfig[](0),
            borrowFee: Types.ActionFeeConfig(0, false),
            repayFee: Types.ActionFeeConfig(0, false),
            withdrawFee: Types.ActionFeeConfig(0, false),
            flashFee: Types.ActionFeeConfig(0, false),
            closeRollingFee: Types.ActionFeeConfig(0, false)
        });

        viewFacet.initPoolWithFullConfig(PID, address(0xBADA55), config);

        (
            bool isCapped,
            uint256 depositCap,
            address underlying,
            uint16 depositorLTVBps,
            uint16 rollingApyBps
        ) = viewFacet.getPoolConfigSummary(PID);

        Types.PoolConfig memory full = viewFacet.getPoolConfig(PID);
        assertEq(isCapped, full.isCapped);
        assertEq(depositCap, full.depositCap);
        assertEq(underlying, address(0xBADA55));
        assertEq(depositorLTVBps, full.depositorLTVBps);
        assertEq(rollingApyBps, full.rollingApyBps);
    }

    function testGetAumFeeInfoReturnsCurrentFeeAndBounds() public {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](0);
        Types.PoolConfig memory config = Types.PoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 100,
            flashLoanFeeBps: 50,
            flashLoanAntiSplit: true,
            minDepositAmount: 1 ether,
            minLoanAmount: 0.5 ether,
            minTopupAmount: 0.1 ether,
            isCapped: false,
            depositCap: 0,
            maxUserCount: 0,
            aumFeeMinBps: 25,
            aumFeeMaxBps: 200,
            fixedTermConfigs: fixedTerms,
            borrowFee: Types.ActionFeeConfig(0, false),
            repayFee: Types.ActionFeeConfig(0, false),
            withdrawFee: Types.ActionFeeConfig(0, false),
            flashFee: Types.ActionFeeConfig(0, false),
            closeRollingFee: Types.ActionFeeConfig(0, false)
        });

        viewFacet.initPoolWithFullConfig(PID, address(0xBEEF), config);
        
        // Initially should be at minimum
        (uint16 currentFeeBps, uint16 minBps, uint16 maxBps) = viewFacet.getAumFeeInfo(PID);
        assertEq(currentFeeBps, 25);
        assertEq(minBps, 25);
        assertEq(maxBps, 200);

        // Update current fee
        viewFacet.setAumFee(PID, 150);
        
        (currentFeeBps, minBps, maxBps) = viewFacet.getAumFeeInfo(PID);
        assertEq(currentFeeBps, 150);
        assertEq(minBps, 25);
        assertEq(maxBps, 200);
    }

    function testIsPoolDeprecatedReturnsCorrectFlag() public {
        viewFacet.initPool(PID, address(0xCAFE), false, 0);
        
        // Initially should not be deprecated
        assertFalse(viewFacet.isPoolDeprecated(PID));
        
        // Mark as deprecated
        viewFacet.setDeprecated(PID, true);
        assertTrue(viewFacet.isPoolDeprecated(PID));
        
        // Unmark as deprecated
        viewFacet.setDeprecated(PID, false);
        assertFalse(viewFacet.isPoolDeprecated(PID));
    }

    function testGetPoolInfoReturnsCompletePoolData() public {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({
            durationSecs: 60 days,
            apyBps: 1000
        });

        Types.PoolConfig memory config = Types.PoolConfig({
            rollingApyBps: 450,
            depositorLTVBps: 7500,
            maintenanceRateBps: 80,
            flashLoanFeeBps: 30,
            flashLoanAntiSplit: false,
            minDepositAmount: 2 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.2 ether,
            isCapped: true,
            depositCap: 5000 ether,
            maxUserCount: 500,
            aumFeeMinBps: 15,
            aumFeeMaxBps: 150,
            fixedTermConfigs: fixedTerms,
            borrowFee: Types.ActionFeeConfig(0, false),
            repayFee: Types.ActionFeeConfig(0, false),
            withdrawFee: Types.ActionFeeConfig(0, false),
            flashFee: Types.ActionFeeConfig(0, false),
            closeRollingFee: Types.ActionFeeConfig(0, false)
        });

        address underlyingAddr = address(0xABCD);
        viewFacet.initPoolWithFullConfig(PID, underlyingAddr, config);
        viewFacet.setAumFee(PID, 75);
        viewFacet.setTotalDeposits(PID, 1000 ether);
        viewFacet.setDeprecated(PID, true);

        // Get complete pool info
        (
            address underlying,
            Types.PoolConfig memory returnedConfig,
            uint16 currentAumFeeBps,
            uint256 totalDeposits,
            bool deprecated
        ) = viewFacet.getPoolInfo(PID);

        // Verify all fields
        assertEq(underlying, underlyingAddr);
        assertEq(returnedConfig.rollingApyBps, 450);
        assertEq(returnedConfig.depositorLTVBps, 7500);
        assertEq(returnedConfig.aumFeeMinBps, 15);
        assertEq(returnedConfig.aumFeeMaxBps, 150);
        assertEq(returnedConfig.fixedTermConfigs.length, 1);
        assertEq(currentAumFeeBps, 75);
        assertEq(totalDeposits, 1000 ether);
        assertTrue(deprecated);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract ManagedPoolBasePoolHarness is PoolManagementFacet {
    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setDefaultPoolConfig(Types.PoolConfig memory config) external {
        Types.PoolConfig storage target = LibAppStorage.s().defaultPoolConfig;
        target.rollingApyBps = config.rollingApyBps;
        target.depositorLTVBps = config.depositorLTVBps;
        target.maintenanceRateBps = config.maintenanceRateBps;
        target.flashLoanFeeBps = config.flashLoanFeeBps;
        target.flashLoanAntiSplit = config.flashLoanAntiSplit;
        target.minDepositAmount = config.minDepositAmount;
        target.minLoanAmount = config.minLoanAmount;
        target.minTopupAmount = config.minTopupAmount;
        target.isCapped = config.isCapped;
        target.depositCap = config.depositCap;
        target.maxUserCount = config.maxUserCount;
        target.aumFeeMinBps = config.aumFeeMinBps;
        target.aumFeeMaxBps = config.aumFeeMaxBps;
        target.borrowFee = config.borrowFee;
        target.repayFee = config.repayFee;
        target.withdrawFee = config.withdrawFee;
        target.flashFee = config.flashFee;
        target.closeRollingFee = config.closeRollingFee;
        delete target.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function poolInfo(uint256 pid) external view returns (bool initialized, address underlying) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.initialized, p.underlying);
    }

    function assetPoolId(address underlying) external view returns (uint256) {
        return LibAppStorage.s().assetToPoolId[underlying];
    }
}

contract ManagedPoolBasePoolAutoCreatePropertyTest is Test {
    ManagedPoolBasePoolHarness internal facet;

    function setUp() public {
        facet = new ManagedPoolBasePoolHarness();
        facet.setTreasury(address(0xBEEF));
        facet.setManagedPoolCreationFee(0.1 ether);
        facet.setPoolCreationFee(1 ether);
        facet.setDefaultPoolConfig(_defaultConfig());
    }

    function testFuzz_basePoolAutoCreated(address underlying) public {
        underlying = address(uint160(bound(uint256(uint160(underlying)), 1, type(uint160).max)));

        Types.ManagedPoolConfig memory cfg = _managedConfig();
        uint256 managedPid = 2;

        facet.initManagedPool{value: 0.1 ether}(managedPid, underlying, cfg);

        uint256 basePid = facet.assetPoolId(underlying);
        assertTrue(basePid != 0, "base pool not registered");
        (bool initialized, address storedUnderlying) = facet.poolInfo(basePid);
        assertTrue(initialized, "base pool not initialized");
        assertEq(storedUnderlying, underlying, "base pool underlying mismatch");
    }

    function _defaultConfig() internal pure returns (Types.PoolConfig memory config) {
        Types.FixedTermConfig[] memory terms = new Types.FixedTermConfig[](1);
        terms[0] = Types.FixedTermConfig({durationSecs: 30 days, apyBps: 500});

        config.rollingApyBps = 500;
        config.depositorLTVBps = 5000;
        config.maintenanceRateBps = 100;
        config.flashLoanFeeBps = 10;
        config.flashLoanAntiSplit = false;
        config.minDepositAmount = 1;
        config.minLoanAmount = 1;
        config.minTopupAmount = 1;
        config.isCapped = false;
        config.depositCap = 0;
        config.maxUserCount = 0;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 100;
        config.fixedTermConfigs = terms;

        config.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

    function _managedConfig() internal pure returns (Types.ManagedPoolConfig memory cfg) {
        Types.FixedTermConfig[] memory terms = new Types.FixedTermConfig[](1);
        terms[0] = Types.FixedTermConfig({durationSecs: 30 days, apyBps: 500});

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 5000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 10;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = terms;
        cfg.actionFees = Types.ActionFeeSet({
            borrowFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            repayFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            withdrawFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            flashFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            closeRollingFee: Types.ActionFeeConfig({amount: 0, enabled: false})
        });
        cfg.manager = address(0);
        cfg.whitelistEnabled = true;
    }
}

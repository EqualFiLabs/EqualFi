// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    InvalidManagedPoolConfig,
    PoolNotManaged,
    OnlyManagerAllowed,
    InvalidManagerTransfer
} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolErrorHarness is PoolManagementFacet {
    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
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

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function poolManager(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].manager;
    }
}

contract ManagedPoolErrorsTest is Test {
    ManagedPoolErrorHarness internal harness;
    MockERC20 internal underlying;
    address internal treasury = address(0x1111);
    address internal creator = address(0xBEEF);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        harness = new ManagedPoolErrorHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        harness.setOwner(address(this));
        harness.setTreasury(treasury);
        harness.setManagedPoolCreationFee(0.1 ether);
        harness.setPoolCreationFee(0.05 ether);
        harness.setDefaultPoolConfig(_poolConfig());
    }

    function _managedConfig() internal pure returns (Types.ManagedPoolConfig memory cfg) {
        Types.ActionFeeSet memory actionFees;
        cfg = Types.ManagedPoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 50,
            flashLoanFeeBps: 10,
            flashLoanAntiSplit: false,
            minDepositAmount: 1 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.1 ether,
            isCapped: false,
            depositCap: 0,
            maxUserCount: 0,
            aumFeeMinBps: 100,
            aumFeeMaxBps: 500,
            fixedTermConfigs: new Types.FixedTermConfig[](0),
            actionFees: actionFees,
            manager: address(0),
            whitelistEnabled: true
        });
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.isCapped = false;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
    }

    function testInvalidManagedPoolConfigManagerMismatch() public {
        Types.ManagedPoolConfig memory cfg = _managedConfig();
        cfg.manager = address(0xABCD);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidManagedPoolConfig.selector, "manager must be msg.sender or zero")
        );
        harness.initManagedPool{value: 0.1 ether}(MANAGED_PID, address(underlying), cfg);
    }

    function testInvalidManagedPoolConfigWhitelistDisabled() public {
        Types.ManagedPoolConfig memory cfg = _managedConfig();
        cfg.whitelistEnabled = false;

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidManagedPoolConfig.selector, "whitelistEnabled must be true")
        );
        harness.initManagedPool{value: 0.1 ether}(MANAGED_PID, address(underlying), cfg);
    }

    function testPoolNotManagedOnManagedSetter() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        uint256 unmanagedPid = harness.initPool{value: 0.05 ether}(address(underlying));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolNotManaged.selector, unmanagedPid));
        harness.setRollingApy(unmanagedPid, 700);
    }

    function testOnlyManagerAllowedAfterRenounce() public {
        Types.ManagedPoolConfig memory cfg = _managedConfig();
        cfg.manager = creator;
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        harness.initManagedPool{value: 0.1 ether}(2, address(underlying), cfg);

        vm.prank(creator);
        harness.renounceManager(2);
        assertEq(harness.poolManager(2), address(0), "manager cleared");

        vm.prank(creator);
        vm.expectRevert(OnlyManagerAllowed.selector);
        harness.setRollingApy(2, 700);
    }
}

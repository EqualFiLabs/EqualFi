// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {NotPoolManager, InvalidManagerTransfer, ManagerAlreadyRenounced} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolManagerHarness is PoolManagementFacet {
    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
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

/// **Feature: managed-pools, Property 12: Manager transfer and renunciation**
/// **Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5**
contract ManagedPoolManagerPropertyTest is Test {
    ManagedPoolManagerHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xBEEF);
    address internal manager = address(0xA11CE);
    address internal newManager = address(0xB0B);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolManagerHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setManagedPoolCreationFee(0.05 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_defaultPoolConfig());

        Types.ManagedPoolConfig memory cfg;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.isCapped = false;
        cfg.manager = manager;
        cfg.whitelistEnabled = true;

        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.05 ether}(MANAGED_PID, address(underlying), cfg);
    }

    function testProperty_ManagerTransferAndRenounce() public {
        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.ManagerTransferred(MANAGED_PID, manager, newManager);
        vm.prank(manager);
        facet.transferManager(MANAGED_PID, newManager);
        assertEq(facet.poolManager(MANAGED_PID), newManager, "manager updated");

        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, manager, newManager));
        vm.prank(manager);
        facet.renounceManager(MANAGED_PID);

        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.ManagerRenounced(MANAGED_PID, newManager);
        vm.prank(newManager);
        facet.renounceManager(MANAGED_PID);
        assertEq(facet.poolManager(MANAGED_PID), address(0), "manager renounced");

        vm.expectRevert(ManagerAlreadyRenounced.selector);
        vm.prank(newManager);
        facet.renounceManager(MANAGED_PID);
    }

    function testTransferManagerZeroAddressForbidden() public {
        vm.prank(manager);
        vm.expectRevert(InvalidManagerTransfer.selector);
        facet.transferManager(MANAGED_PID, address(0));
    }

    function _defaultPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
    }
}

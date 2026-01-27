// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {InsufficientManagedPoolCreationFee, InsufficientPoolCreationFee} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeIsolationHarness is PoolManagementFacet {
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

    function isManaged(uint256 pid) external view returns (bool) {
        return LibAppStorage.s().pools[pid].isManagedPool;
    }
}

/// **Feature: managed-pools, Property 9: Fee type isolation**
/// **Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5, 6.6**
contract FeeIsolationPropertyTest is Test {
    FeeIsolationHarness internal harness;
    MockERC20 internal underlying;
    address internal treasury = address(0xFEe5);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        harness = new FeeIsolationHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        harness.setTreasury(treasury);
        harness.setOwner(address(this));
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

    function testProperty_FeeTypeIsolation(address managedCreator, address unmanagedCreator) public {
        managedCreator = address(uint160(bound(uint256(uint160(managedCreator)), 1, type(uint160).max - 1)));
        unmanagedCreator =
            address(uint160(bound(uint256(uint160(unmanagedCreator)), 1, type(uint160).max - 1)));
        vm.assume(managedCreator != treasury);
        vm.assume(unmanagedCreator != treasury);
        vm.assume(unmanagedCreator != address(this));

        MockERC20 otherUnderlying = new MockERC20("Underlying2", "UND2", 18, 0);
        uint256 managedFee = 0.2 ether;
        uint256 unmanagedFee = 0.05 ether;
        harness.setManagedPoolCreationFee(managedFee);
        harness.setPoolCreationFee(unmanagedFee);

        Types.ManagedPoolConfig memory mCfg = _managedConfig();
        mCfg.manager = managedCreator;

        vm.deal(managedCreator, 1 ether);
        uint256 balBefore = treasury.balance;

        // Managed pools must use managedPoolCreationFee, not poolCreationFee
        vm.prank(managedCreator);
        vm.expectRevert(abi.encodeWithSelector(InsufficientManagedPoolCreationFee.selector, managedFee, unmanagedFee));
        harness.initManagedPool{value: unmanagedFee}(MANAGED_PID, address(underlying), mCfg);

        vm.prank(managedCreator);
        harness.initManagedPool{value: managedFee}(MANAGED_PID, address(underlying), mCfg);

        assertEq(treasury.balance - balBefore, managedFee, "managed fee routed");
        assertTrue(harness.isManaged(MANAGED_PID), "managed pool flagged");

        vm.deal(unmanagedCreator, 1 ether);
        uint256 balMid = treasury.balance;

        // Unmanaged pools must use poolCreationFee, not managedPoolCreationFee
        vm.prank(unmanagedCreator);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolCreationFee.selector, unmanagedFee, managedFee));
        harness.initPool{value: managedFee}(address(otherUnderlying));

        vm.prank(unmanagedCreator);
        uint256 unmanagedPid = harness.initPool{value: unmanagedFee}(address(otherUnderlying));

        assertEq(treasury.balance - balMid, unmanagedFee, "unmanaged fee routed");
        assertFalse(harness.isManaged(unmanagedPid), "unmanaged pool flagged");
    }
}

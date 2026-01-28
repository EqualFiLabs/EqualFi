// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    NotPoolManager,
    PoolNotManaged,
    InvalidAPYRate,
    InvalidLTVRatio,
    InvalidMinimumThreshold,
    InvalidDepositCap,
    InvalidMaintenanceRate,
    InvalidFlashLoanFee,
    ActionFeeBoundsViolation
} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolSetterHarness is PoolManagementFacet {
    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setActionFeeBounds(uint128 minAmount, uint128 maxAmount) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.actionFeeMin = minAmount;
        store.actionFeeMax = maxAmount;
        store.actionFeeBoundsSet = true;
    }

    function setMaxMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().maxMaintenanceRateBps = rate;
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

    function managedConfig(uint256 pid) external view returns (Types.ManagedPoolConfig memory) {
        return LibAppStorage.s().pools[pid].managedConfig;
    }

    function forceDepositCap(uint256 pid, uint256 cap) external {
        LibAppStorage.s().pools[pid].managedConfig.depositCap = cap;
    }
}

/// **Feature: managed-pools, Property 3: Parameter update validation and access control**
/// **Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6**
contract ManagedPoolParameterUpdatePropertyTest is Test {
    ManagedPoolSetterHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xBEEF);
    address internal manager = address(0xA11CE);
    address internal nonManager = address(0xB0B);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolSetterHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setManagedPoolCreationFee(0.1 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_defaultPoolConfig());
    }

    function _managedConfig(uint256 depositCap) internal view returns (Types.ManagedPoolConfig memory cfg) {
        Types.ActionFeeSet memory fees;
        fees.borrowFee = Types.ActionFeeConfig({amount: 1 ether, enabled: true});
        cfg = Types.ManagedPoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 50,
            flashLoanFeeBps: 10,
            flashLoanAntiSplit: false,
            minDepositAmount: 1 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.1 ether,
            isCapped: true,
            depositCap: depositCap,
            maxUserCount: 10,
            aumFeeMinBps: 100,
            aumFeeMaxBps: 500,
            fixedTermConfigs: new Types.FixedTermConfig[](0),
            actionFees: fees,
            manager: manager,
            whitelistEnabled: true
        });
    }

    function _initManagedPool(uint256 pid, uint256 depositCap) internal {
        Types.ManagedPoolConfig memory cfg = _managedConfig(depositCap);
        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.1 ether}(pid, address(underlying), cfg);
    }

    function testProperty_ParameterUpdateValidationAndAccess(
        uint16 newRollingApy,
        uint16 newLtv,
        uint16 newMaintenance,
        uint16 newFlashFee,
        uint256 newMinDeposit,
        uint256 newMinLoan,
        uint256 newMinTopup,
        uint256 newDepositCap,
        uint256 newMaxUsers,
        uint128 newBorrowFee
    ) public {
        _initManagedPool(MANAGED_PID, 100 ether);

        newRollingApy = uint16(bound(newRollingApy, 0, 10_000));
        newLtv = uint16(bound(newLtv, 1, 10_000));
        newMaintenance = uint16(bound(newMaintenance, 1, 100));
        newFlashFee = uint16(bound(newFlashFee, 0, 10_000));
        newMinDeposit = bound(newMinDeposit, 1, 1e36);
        newMinLoan = bound(newMinLoan, 1, 1e36);
        newMinTopup = bound(newMinTopup, 1, 1e36);
        newDepositCap = bound(newDepositCap, 1, 1e36);
        newMaxUsers = bound(newMaxUsers, 0, 1000);
        newBorrowFee = uint128(bound(newBorrowFee, 0, 1e18));

        vm.prank(manager);
        facet.setRollingApy(MANAGED_PID, newRollingApy);
        vm.prank(manager);
        facet.setDepositorLTV(MANAGED_PID, newLtv);
        vm.prank(manager);
        facet.setMinDepositAmount(MANAGED_PID, newMinDeposit);
        vm.prank(manager);
        facet.setMinLoanAmount(MANAGED_PID, newMinLoan);
        vm.prank(manager);
        facet.setMinTopupAmount(MANAGED_PID, newMinTopup);
        vm.prank(manager);
        facet.setDepositCap(MANAGED_PID, newDepositCap);
        vm.prank(manager);
        facet.setIsCapped(MANAGED_PID, true);
        vm.prank(manager);
        facet.setMaxUserCount(MANAGED_PID, newMaxUsers);
        vm.prank(manager);
        facet.setMaintenanceRate(MANAGED_PID, newMaintenance);
        vm.prank(manager);
        facet.setFlashLoanFee(MANAGED_PID, newFlashFee);

        Types.ActionFeeSet memory newFees;
        newFees.borrowFee = Types.ActionFeeConfig({amount: newBorrowFee, enabled: true});
        vm.prank(manager);
        facet.setActionFees(MANAGED_PID, newFees);

        Types.ManagedPoolConfig memory stored = facet.managedConfig(MANAGED_PID);
        assertEq(stored.rollingApyBps, newRollingApy, "rolling apy updated");
        assertEq(stored.depositorLTVBps, newLtv, "ltv updated");
        assertEq(stored.minDepositAmount, newMinDeposit, "min deposit updated");
        assertEq(stored.minLoanAmount, newMinLoan, "min loan updated");
        assertEq(stored.minTopupAmount, newMinTopup, "min topup updated");
        assertEq(stored.depositCap, newDepositCap, "deposit cap updated");
        assertTrue(stored.isCapped, "capped flag updated");
        assertEq(stored.maxUserCount, newMaxUsers, "max users updated");
        assertEq(stored.maintenanceRateBps, newMaintenance, "maintenance updated");
        assertEq(stored.flashLoanFeeBps, newFlashFee, "flash fee updated");
        assertEq(stored.actionFees.borrowFee.amount, newBorrowFee, "action fee updated");

        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, nonManager, manager));
        vm.prank(nonManager);
        facet.setRollingApy(MANAGED_PID, newRollingApy);
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

/// **Feature: managed-pools, Property 11: Parameter bounds enforcement**
/// **Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7**
contract ManagedPoolParameterBoundsPropertyTest is Test {
    ManagedPoolSetterHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xCAFE);
    address internal manager = address(0xA11CE);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolSetterHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setManagedPoolCreationFee(0.05 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
        facet.setMaxMaintenanceRate(100); // 1% cap for tests
        facet.setDefaultPoolConfig(_defaultPoolConfig());
        _initManagedPool();
    }

    function _initManagedPool() internal {
        Types.ManagedPoolConfig memory cfg;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.isCapped = true;
        cfg.depositCap = 100 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.whitelistEnabled = true;
        cfg.manager = manager;
        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.05 ether}(MANAGED_PID, address(underlying), cfg);
    }

    function testRollingApyBound() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAPYRate.selector, "rollingApyBps > 100%"));
        vm.prank(manager);
        facet.setRollingApy(MANAGED_PID, 10_001);
    }

    function testLtvBound() public {
        vm.expectRevert(InvalidLTVRatio.selector);
        vm.prank(manager);
        facet.setDepositorLTV(MANAGED_PID, 0);

        vm.expectRevert(InvalidLTVRatio.selector);
        vm.prank(manager);
        facet.setDepositorLTV(MANAGED_PID, 10_001);
    }


    function testMinThresholdsBound() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidMinimumThreshold.selector, "minDepositAmount must be > 0"));
        vm.prank(manager);
        facet.setMinDepositAmount(MANAGED_PID, 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidMinimumThreshold.selector, "minLoanAmount must be > 0"));
        vm.prank(manager);
        facet.setMinLoanAmount(MANAGED_PID, 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidMinimumThreshold.selector, "minTopupAmount must be > 0"));
        vm.prank(manager);
        facet.setMinTopupAmount(MANAGED_PID, 0);
    }

    function testDepositCapValidation() public {
        vm.expectRevert(InvalidDepositCap.selector);
        vm.prank(manager);
        facet.setDepositCap(MANAGED_PID, 0);

        // force deposit cap to zero and ensure capped cannot be enabled
        facet.forceDepositCap(MANAGED_PID, 0);
        vm.expectRevert(InvalidDepositCap.selector);
        vm.prank(manager);
        facet.setIsCapped(MANAGED_PID, true);
    }

    function testMaintenanceRateBound() public {
        vm.expectRevert(InvalidMaintenanceRate.selector);
        vm.prank(manager);
        facet.setMaintenanceRate(MANAGED_PID, 101);
    }

    function testFlashLoanFeeBound() public {
        vm.expectRevert(InvalidFlashLoanFee.selector);
        vm.prank(manager);
        facet.setFlashLoanFee(MANAGED_PID, 10_001);
    }

    function testActionFeeBounds() public {
        facet.setActionFeeBounds(1, 5);
        Types.ActionFeeSet memory fees;
        fees.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: true});
        vm.expectRevert(abi.encodeWithSelector(ActionFeeBoundsViolation.selector, uint128(0), uint128(1), uint128(5)));
        vm.prank(manager);
        facet.setActionFees(MANAGED_PID, fees);
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

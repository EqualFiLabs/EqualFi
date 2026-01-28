// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    ManagedPoolCreationDisabled,
    InsufficientManagedPoolCreationFee,
    InvalidTreasuryAddress
} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolManagementHarness is PoolManagementFacet {
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

    function setMaxMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().maxMaintenanceRateBps = rate;
    }

    function setDefaultMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().defaultMaintenanceRateBps = rate;
    }

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function poolInfo(uint256 pid)
        external
        view
        returns (bool isManagedPool, address manager, bool whitelistEnabled, address underlying)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.isManagedPool, p.manager, p.whitelistEnabled, p.underlying);
    }

    function managedConfig(uint256 pid) external view returns (Types.ManagedPoolConfig memory) {
        return LibAppStorage.s().pools[pid].managedConfig;
    }

}

/// **Feature: managed-pools, Property 1: Managed pool creation completeness**
/// **Validates: Requirements 1.1, 1.5, 1.6, 1.7**
contract ManagedPoolCreationPropertyTest is Test {
    ManagedPoolManagementHarness internal facet;
    MockERC20 internal underlying;
    MockERC20 internal otherUnderlying;
    address internal treasury = address(0xBEEF);
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolManagementHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        otherUnderlying = new MockERC20("UnderlyingB", "UNDB", 18, 0);
        facet.setTreasury(treasury);
        facet.setManagedPoolCreationFee(0.1 ether);
        facet.setDefaultPoolConfig(_defaultPoolConfig());
        facet.setOwner(address(this)); // owner set for completeness; fee still required
    }

    function _managedConfig(
        uint16 rollingApy,
        uint16 rollingApyExternal,
        uint16 ltv,
        uint16 cr,
        uint16 maintenance,
        uint16 flashFee,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        bool isCapped,
        uint256 depositCap,
        uint256 maxUsers
    ) internal pure returns (Types.ManagedPoolConfig memory cfg) {
        Types.FixedTermConfig[] memory terms = new Types.FixedTermConfig[](1);
        terms[0] = Types.FixedTermConfig({durationSecs: 30 days, apyBps: 500});

        Types.ActionFeeSet memory actionFees;
        actionFees.borrowFee = Types.ActionFeeConfig({amount: 1 ether, enabled: true});
        actionFees.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});

        cfg = Types.ManagedPoolConfig({
            rollingApyBps: rollingApy,
            depositorLTVBps: ltv,
            maintenanceRateBps: maintenance,
            flashLoanFeeBps: flashFee,
            flashLoanAntiSplit: true,
            minDepositAmount: minDeposit,
            minLoanAmount: minLoan,
            minTopupAmount: minTopup,
            isCapped: isCapped,
            depositCap: depositCap,
            maxUserCount: maxUsers,
            aumFeeMinBps: 100,
            aumFeeMaxBps: 500,
            fixedTermConfigs: terms,
            actionFees: actionFees,
            manager: address(0),
            whitelistEnabled: true
        });
    }

    function testProperty_ManagedPoolCreationCompleteness(
        address creator,
        uint16 rollingApy,
        uint16 rollingApyExternal,
        uint16 ltv,
        uint16 cr,
        uint16 maintenance,
        uint16 flashFee,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint256 depositCap,
        uint256 maxUsers
    ) public {
        creator = address(uint160(bound(uint256(uint160(creator)), 1, type(uint160).max - 1)));
        rollingApy = uint16(bound(rollingApy, 1, 10_000));
        rollingApyExternal = uint16(bound(rollingApyExternal, 1, 10_000));
        ltv = uint16(bound(ltv, 1, 10_000));
        cr = uint16(bound(cr, 1, 50_000));
        maintenance = uint16(bound(maintenance, 1, 100));
        flashFee = uint16(bound(flashFee, 0, 10_000));
        minDeposit = bound(minDeposit, 1, 1e36);
        minLoan = bound(minLoan, 1, 1e36);
        minTopup = bound(minTopup, 1, 1e36);
        maxUsers = bound(maxUsers, 0, 1000);
        bool isCapped = true;
        depositCap = bound(depositCap, 1, 1e36);

        Types.ManagedPoolConfig memory cfg = _managedConfig(
            rollingApy,
            rollingApyExternal,
            ltv,
            cr,
            maintenance,
            flashFee,
            minDeposit,
            minLoan,
            minTopup,
            isCapped,
            depositCap,
            maxUsers
        );

        cfg.manager = creator;
        cfg.whitelistEnabled = true;

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectEmit(true, true, false, false);
        emit PoolManagementFacet.PoolInitialized(1, address(underlying), _defaultPoolConfig());
        vm.expectEmit(true, true, true, false);
        emit PoolManagementFacet.PoolInitializedManaged(MANAGED_PID, address(underlying), creator, cfg);
        facet.initManagedPool{value: 0.1 ether}(MANAGED_PID, address(underlying), cfg);

        (bool isManagedPool, address manager, bool whitelistEnabled, address storedUnderlying) =
            facet.poolInfo(MANAGED_PID);
        Types.ManagedPoolConfig memory storedConfig = facet.managedConfig(MANAGED_PID);

        assertTrue(isManagedPool, "managed flag set");
        assertEq(manager, creator, "manager stored");
        assertTrue(whitelistEnabled, "whitelist enabled");
        assertEq(storedUnderlying, address(underlying), "underlying stored");
        assertEq(storedConfig.rollingApyBps, rollingApy, "rolling apy stored");
        assertEq(storedConfig.minDepositAmount, minDeposit, "min deposit stored");
        assertEq(storedConfig.aumFeeMinBps, 100, "aum fee min stored");
        assertEq(storedConfig.fixedTermConfigs.length, 1, "fixed term stored");
        assertEq(storedConfig.fixedTermConfigs[0].durationSecs, 30 days, "fixed term duration stored");
    }

    function testManagedPoolAllowsTokenWithPermissionlessPool() public {
        Types.PoolConfig memory immutCfg;
        immutCfg.minDepositAmount = 1 ether;
        immutCfg.minLoanAmount = 1 ether;
        immutCfg.minTopupAmount = 0.1 ether;
        immutCfg.aumFeeMinBps = 100;
        immutCfg.aumFeeMaxBps = 500;
        immutCfg.depositorLTVBps = 8000;
        immutCfg.maintenanceRateBps = 50;
        immutCfg.flashLoanFeeBps = 10;
        immutCfg.rollingApyBps = 500;

        facet.setPoolCreationFee(0.05 ether);
        facet.setDefaultPoolConfig(immutCfg);
        address payer = address(0xB0B);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        facet.initPool{value: 0.05 ether}(address(otherUnderlying));

        Types.ManagedPoolConfig memory cfg = _managedConfig(
            500,
            600,
            8000,
            15000,
            50,
            10,
            1 ether,
            1 ether,
            0.1 ether,
            false,
            0,
            0
        );

        address creator = address(0xCAFE);
        cfg.manager = creator;
        cfg.whitelistEnabled = true;
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        facet.initManagedPool{value: 0.1 ether}(MANAGED_PID, address(otherUnderlying), cfg);
        (bool isManagedPool,, , address storedUnderlying) = facet.poolInfo(MANAGED_PID);
        assertTrue(isManagedPool, "managed pool created");
        assertEq(storedUnderlying, address(otherUnderlying), "managed pool uses same token");
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

/// **Feature: managed-pools, Property 2: Fee collection and routing**
/// **Validates: Requirements 1.2**
contract ManagedPoolCreationFeePropertyTest is Test {
    ManagedPoolManagementHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xCAFE);

    function setUp() public {
        facet = new ManagedPoolManagementHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setTreasury(treasury);
        facet.setManagedPoolCreationFee(0.2 ether);
        facet.setDefaultPoolConfig(_defaultPoolConfig());
    }

    function testProperty_FeeCollectionAndRouting(address creator) public {
        creator = address(uint160(bound(uint256(uint160(creator)), 1, type(uint160).max - 1)));
        // If the treasury itself pays the fee, the outgoing msg.value offsets the incoming transfer
        // and the observed delta is zero. Exclude that degenerate case for this routing property.
        vm.assume(creator != treasury);
        Types.ManagedPoolConfig memory cfg = Types.ManagedPoolConfig({
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
            actionFees: Types.ActionFeeSet({
                borrowFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                repayFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                withdrawFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                flashFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                closeRollingFee: Types.ActionFeeConfig({amount: 0, enabled: false})
            }),
            manager: address(0),
            whitelistEnabled: true
        });

        vm.deal(creator, 1 ether);
        uint256 balBefore = treasury.balance;

        vm.prank(creator);
        facet.initManagedPool{value: 0.2 ether}(5, address(underlying), cfg);

        assertEq(treasury.balance - balBefore, 0.2 ether, "fee routed to treasury");
        (bool isManagedPool,, bool whitelistEnabled, address storedUnderlying) = facet.poolInfo(5);
        assertTrue(isManagedPool, "managed flag");
        assertTrue(whitelistEnabled, "whitelist enabled");
        assertEq(storedUnderlying, address(underlying), "underlying set");
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

contract ManagedPoolCreationErrorTests is Test {
    ManagedPoolManagementHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xF00D);

    function setUp() public {
        facet = new ManagedPoolManagementHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setDefaultPoolConfig(_defaultPoolConfig());
    }

    /// **Feature: managed-pools, Property 4: Fee validation and error handling**
    /// **Validates: Requirements 1.4**
    function testProperty_ManagedPoolCreationInvalidFee() public {
        facet.setManagedPoolCreationFee(0.3 ether);
        facet.setTreasury(treasury);

        Types.ManagedPoolConfig memory cfg = Types.ManagedPoolConfig({
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
            actionFees: Types.ActionFeeSet({
                borrowFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                repayFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                withdrawFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                flashFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                closeRollingFee: Types.ActionFeeConfig({amount: 0, enabled: false})
            }),
            manager: address(0),
            whitelistEnabled: true
        });

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(InsufficientManagedPoolCreationFee.selector, 0.3 ether, 0.1 ether));
        facet.initManagedPool{value: 0.1 ether}(7, address(underlying), cfg);
    }

    function testManagedPoolCreationDisabledWhenFeeZero() public {
        facet.setManagedPoolCreationFee(0);
        facet.setTreasury(treasury);

        Types.ManagedPoolConfig memory cfg = Types.ManagedPoolConfig({
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
            actionFees: Types.ActionFeeSet({
                borrowFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                repayFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                withdrawFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                flashFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
                closeRollingFee: Types.ActionFeeConfig({amount: 0, enabled: false})
            }),
            manager: address(0),
            whitelistEnabled: true
        });

        vm.deal(address(this), 1 ether);
        vm.expectRevert(ManagedPoolCreationDisabled.selector);
        facet.initManagedPool{value: 0}(9, address(underlying), cfg);
    }

    function testManagedPoolCreationFailsWhenTreasuryMissing() public {
        facet.setManagedPoolCreationFee(0.5 ether);
        // treasury intentionally unset (zero)

        Types.ManagedPoolConfig memory cfg;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;

        vm.deal(address(this), 1 ether);
        vm.expectRevert(InvalidTreasuryAddress.selector);
        facet.initManagedPool{value: 0.5 ether}(10, address(underlying), cfg);
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

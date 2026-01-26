// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PoolMembershipRequired, InsufficientPoolCreationFee} from "../../src/libraries/Errors.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract UnmanagedIsolationHarness is PoolManagementFacet {
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

    function managerOf(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].manager;
    }

    function whitelistFlag(uint256 pid) external view returns (bool) {
        return LibAppStorage.s().pools[pid].whitelistEnabled;
    }

    function ensureMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) external returns (bool) {
        return LibPoolMembership._ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }
}

/// **Feature: managed-pools, Property 7: Unmanaged pool isolation**
/// **Validates: Requirements 4.1, 4.2, 4.3**
contract UnmanagedPoolIsolationPropertyTest is Test {
    UnmanagedIsolationHarness internal harness;
    MockERC20 internal underlying;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        harness = new UnmanagedIsolationHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        harness.setOwner(address(this));
        harness.setTreasury(treasury);
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

    function testProperty_UnmanagedPoolIsolation(
        uint256 pid,
        address payer,
        address user
    ) public {
        pid = bound(pid, 1, 1000);
        payer = address(uint160(bound(uint256(uint160(payer)), 1, type(uint160).max - 1)));
        if (payer == address(this)) {
            payer = address(0xB0B1);
        }
        if (payer == treasury) {
            payer = address(0xB0B2);
            if (payer == address(this)) {
                payer = address(0xB0B3);
            }
        }
        user = address(uint160(bound(uint256(uint160(user)), 1, type(uint160).max - 1)));

        Types.PoolConfig memory cfg = _poolConfig();

        harness.setDefaultPoolConfig(cfg);

        // Pay unmanaged pool creation fee
        harness.setPoolCreationFee(0.1 ether);
        vm.deal(payer, 1 ether);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(payer);
        uint256 createdPid = harness.initPool{value: 0.1 ether}(address(underlying));

        assertEq(treasury.balance - treasuryBefore, 0.1 ether, "poolCreationFee routed");
        assertFalse(harness.isManaged(createdPid), "unmanaged flag");
        assertEq(harness.managerOf(createdPid), address(0), "no manager");
        assertFalse(harness.whitelistFlag(createdPid), "whitelist flag default false");

        bytes32 userKey = LibPositionHelpers.systemPositionKey(user);
        bool firstJoin = harness.ensureMembership(userKey, createdPid, true);
        assertFalse(firstJoin, "auto join allowed unmanaged");
        bool secondJoin = harness.ensureMembership(userKey, createdPid, true);
        assertTrue(secondJoin, "membership retained");

        // Use an address that has not joined to verify manual join path still reverts
        address outsider = address(this);
        if (outsider == user) {
            outsider = address(0xCAFE);
        }
        bytes32 outsiderKey = LibPositionHelpers.systemPositionKey(outsider);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, outsiderKey, createdPid));
        harness.ensureMembership(outsiderKey, createdPid, false);
    }
}

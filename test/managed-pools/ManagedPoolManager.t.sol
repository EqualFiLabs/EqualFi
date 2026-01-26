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

    function setUp() public {
        facet = new ManagedPoolManagerHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setManagedPoolCreationFee(0.05 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));

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
        facet.initManagedPool{value: 0.05 ether}(1, address(underlying), cfg);
    }

    function testProperty_ManagerTransferAndRenounce() public {
        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.ManagerTransferred(1, manager, newManager);
        vm.prank(manager);
        facet.transferManager(1, newManager);
        assertEq(facet.poolManager(1), newManager, "manager updated");

        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, manager, newManager));
        vm.prank(manager);
        facet.renounceManager(1);

        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.ManagerRenounced(1, newManager);
        vm.prank(newManager);
        facet.renounceManager(1);
        assertEq(facet.poolManager(1), address(0), "manager renounced");

        vm.expectRevert(ManagerAlreadyRenounced.selector);
        vm.prank(newManager);
        facet.renounceManager(1);
    }

    function testTransferManagerZeroAddressForbidden() public {
        vm.prank(manager);
        vm.expectRevert(InvalidManagerTransfer.selector);
        facet.transferManager(1, address(0));
    }
}

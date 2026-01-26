// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PoolNotInitialized} from "../../src/libraries/Errors.sol";

contract PoolInitializationHarness is PoolManagementFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function requirePool(uint256 pid) external view returns (address underlying, bool initialized) {
        Types.PoolData storage p = LibPositionHelpers.pool(pid);
        return (p.underlying, p.initialized);
    }

    function isInitialized(uint256 pid) external view returns (bool) {
        return LibAppStorage.s().pools[pid].initialized;
    }
}

contract PoolInitializationPropertyTest is Test {
    PoolInitializationHarness internal harness;
    Types.PoolConfig internal config;

    function setUp() public {
        harness = new PoolInitializationHarness();
        harness.setOwner(address(this));

        config.minDepositAmount = 1;
        config.minLoanAmount = 1;
        config.minTopupAmount = 1;
        config.depositorLTVBps = 8_000;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 0;
    }

    /// Feature: native-eth-support, Property 3: Pool Initialization Flag Correctness
    function test_poolInitializationFlagCorrectness() public {
        uint256 pid = 1;

        vm.expectRevert(abi.encodeWithSelector(PoolNotInitialized.selector, pid));
        harness.requirePool(pid);

        harness.initPool(pid, address(0), config);

        (address underlying, bool initialized) = harness.requirePool(pid);
        assertEq(underlying, address(0));
        assertTrue(initialized);
        assertTrue(harness.isInitialized(pid));
    }
}

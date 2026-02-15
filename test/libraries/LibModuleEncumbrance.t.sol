// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import "../../src/libraries/Errors.sol";

contract LibModuleEncumbranceHarness {
    function encumber(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function unencumber(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
    }

    function getEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumbered(positionKey, poolId);
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256)
    {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }
}

contract LibModuleEncumbranceTest is Test {
    LibModuleEncumbranceHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    uint256 internal constant POOL_ID = 3;
    uint256 internal constant MODULE_ID_A = 11;
    uint256 internal constant MODULE_ID_B = 22;

    function setUp() public {
        h = new LibModuleEncumbranceHarness();
    }

    function test_encumber_updatesTotals() public {
        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 100);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 100);
        assertEq(h.getEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_ID_A), 100);

        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 50);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 150);
        assertEq(h.getEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_ID_A), 150);

        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_B, 25);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 175);
        assertEq(h.getEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_ID_B), 25);
    }

    function test_unencumber_updatesTotals() public {
        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 120);
        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_B, 30);

        h.unencumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 20);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 130);
        assertEq(h.getEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_ID_A), 100);
        assertEq(h.getEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_ID_B), 30);
    }

    function test_unencumber_revertsWhenOverModuleEncumbrance() public {
        h.encumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 10);
        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 11, 10));
        h.unencumber(POSITION_KEY, POOL_ID, MODULE_ID_A, 11);
    }
}

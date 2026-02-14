// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import "../../src/libraries/Errors.sol";

contract LibEncumbranceModuleHarness {
    function encumberModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibEncumbrance.encumberModule(positionKey, poolId, moduleId, amount);
    }

    function unencumberModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibEncumbrance.unencumberModule(positionKey, poolId, moduleId, amount);
    }

    function encumberIndex(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        LibEncumbrance.encumberIndex(positionKey, poolId, indexId, amount);
    }

    function setDirectEncumbrance(bytes32 positionKey, uint256 poolId, uint256 locked, uint256 lent, uint256 offerEscrow)
        external
    {
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        enc.directLocked = locked;
        enc.directLent = lent;
        enc.directOfferEscrow = offerEscrow;
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function getModuleEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256)
    {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function total(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, poolId);
    }
}

contract LibEncumbranceModuleNamespaceTest is Test {
    LibEncumbranceModuleHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    uint256 internal constant POOL_ID = 9;
    uint256 internal constant MODULE_A = 101;
    uint256 internal constant MODULE_B = 202;
    uint256 internal constant INDEX_ID = 303;

    function setUp() public {
        h = new LibEncumbranceModuleHarness();
    }

    function test_encumberModule_updatesModuleTotalsAndGetters() public {
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_A, 100);
        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID), 100);
        assertEq(h.getModuleEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_A), 100);
        assertEq(h.total(POSITION_KEY, POOL_ID), 100);

        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_A, 40);
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_B, 25);

        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID), 165);
        assertEq(h.getModuleEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_A), 140);
        assertEq(h.getModuleEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_B), 25);
        assertEq(h.total(POSITION_KEY, POOL_ID), 165);
    }

    function test_unencumberModule_updatesModuleTotals() public {
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_A, 120);
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_B, 30);

        h.unencumberModule(POSITION_KEY, POOL_ID, MODULE_A, 20);
        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID), 130);
        assertEq(h.getModuleEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_A), 100);
        assertEq(h.getModuleEncumberedForModule(POSITION_KEY, POOL_ID, MODULE_B), 30);
        assertEq(h.total(POSITION_KEY, POOL_ID), 130);
    }

    function test_unencumberModule_revertsWhenOverModuleEncumbrance() public {
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_A, 10);
        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 11, 10));
        h.unencumberModule(POSITION_KEY, POOL_ID, MODULE_A, 11);
    }

    function test_total_includesModuleEncumbered() public {
        h.setDirectEncumbrance(POSITION_KEY, POOL_ID, 10, 11, 12);
        h.encumberIndex(POSITION_KEY, POOL_ID, INDEX_ID, 13);
        h.encumberModule(POSITION_KEY, POOL_ID, MODULE_A, 14);

        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID), 14);
        assertEq(h.total(POSITION_KEY, POOL_ID), 60);
    }
}

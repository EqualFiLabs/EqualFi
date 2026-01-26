// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import "../../src/libraries/Errors.sol";

contract LibIndexEncumbranceHarness {
    function encumber(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(positionKey, poolId, indexId, amount);
    }

    function unencumber(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, amount);
    }

    function getEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibIndexEncumbrance.getEncumbered(positionKey, poolId);
    }

    function getEncumberedForIndex(bytes32 positionKey, uint256 poolId, uint256 indexId)
        external
        view
        returns (uint256)
    {
        return LibIndexEncumbrance.getEncumberedForIndex(positionKey, poolId, indexId);
    }
}

contract LibIndexEncumbranceTest is Test {
    LibIndexEncumbranceHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    uint256 internal constant POOL_ID = 3;
    uint256 internal constant INDEX_ID_A = 11;
    uint256 internal constant INDEX_ID_B = 22;

    function setUp() public {
        h = new LibIndexEncumbranceHarness();
    }

    function test_encumber_updatesTotals() public {
        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 100);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 100);
        assertEq(h.getEncumberedForIndex(POSITION_KEY, POOL_ID, INDEX_ID_A), 100);

        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 50);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 150);
        assertEq(h.getEncumberedForIndex(POSITION_KEY, POOL_ID, INDEX_ID_A), 150);

        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_B, 25);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 175);
        assertEq(h.getEncumberedForIndex(POSITION_KEY, POOL_ID, INDEX_ID_B), 25);
    }

    function test_unencumber_updatesTotals() public {
        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 120);
        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_B, 30);

        h.unencumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 20);
        assertEq(h.getEncumbered(POSITION_KEY, POOL_ID), 130);
        assertEq(h.getEncumberedForIndex(POSITION_KEY, POOL_ID, INDEX_ID_A), 100);
        assertEq(h.getEncumberedForIndex(POSITION_KEY, POOL_ID, INDEX_ID_B), 30);
    }

    function test_unencumber_revertsWhenOverIndexEncumbrance() public {
        h.encumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 10);
        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 11, 10));
        h.unencumber(POSITION_KEY, POOL_ID, INDEX_ID_A, 11);
    }
}

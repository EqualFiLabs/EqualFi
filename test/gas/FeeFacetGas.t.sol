// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeFacet} from "../../src/core/FeeFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";

contract FeeFacetGasHarness is FeeFacet {
    function seedPool(uint256 pid) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.poolCount = pid + 1;
    }

    function seedPoolActionFee(uint256 pid, bytes32 action, uint128 amount, bool enabled) external {
        LibAppStorage.s().pools[pid].actionFees[action] = Types.ActionFeeConfig(amount, enabled);
    }

    function seedIndex(uint256 indexId) external {
        LibEqualIndex.EqualIndexStorage storage eqStore = LibEqualIndex.s();
        eqStore.indexCount = indexId + 1;
    }

    function seedIndexActionFee(uint256 indexId, bytes32 action, uint128 amount, bool enabled) external {
        LibEqualIndex.s().actionFees[indexId][action] = Types.ActionFeeConfig(amount, enabled);
    }
}

contract FeeFacetViewGasTest is Test {
    FeeFacetGasHarness internal facet;
    uint256 internal constant PID = 1;
    uint256 internal constant INDEX_ID = 1;

    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");

    function setUp() public {
        facet = new FeeFacetGasHarness();
        facet.seedPool(PID);
        facet.seedIndex(INDEX_ID);
        facet.seedPoolActionFee(PID, ACTION_BORROW, 1 ether, true);
        facet.seedIndexActionFee(INDEX_ID, ACTION_BORROW, 2 ether, true);
    }

    function test_gas_GetPoolActionFee() public {
        vm.resumeGasMetering();
        facet.getPoolActionFee(PID, ACTION_BORROW);
    }

    function test_gas_GetIndexActionFee() public {
        vm.resumeGasMetering();
        facet.getIndexActionFee(INDEX_ID, ACTION_BORROW);
    }

    function test_gas_PreviewActionFee() public {
        vm.resumeGasMetering();
        facet.previewActionFee(PID, ACTION_BORROW);
    }

    function test_gas_PreviewIndexActionFee() public {
        vm.resumeGasMetering();
        facet.previewIndexActionFee(INDEX_ID, ACTION_BORROW);
    }

    function test_gas_GetPoolActionFees() public {
        vm.resumeGasMetering();
        facet.getPoolActionFees(PID);
    }

    function test_gas_PreviewActionFees() public {
        vm.resumeGasMetering();
        facet.previewActionFees(PID);
    }
}

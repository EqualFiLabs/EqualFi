// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibEqualIndexFees} from "../../src/libraries/LibEqualIndexFees.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract LibEqualIndexFeesHarness {
    function setActionFee(uint256 indexId, bytes32 action, uint128 amount, bool enabled) external {
        LibEqualIndex.s().actionFees[indexId][action] = Types.ActionFeeConfig({amount: amount, enabled: enabled});
    }

    function actionFeeUnits(uint256 indexId, bytes32 action) external view returns (uint256) {
        return LibEqualIndexFees.actionFeeUnits(indexId, action);
    }
}

contract LibEqualIndexFeesTest is Test {
    LibEqualIndexFeesHarness internal h;

    uint256 internal constant INDEX_ID = 7;
    bytes32 internal constant ACTION = keccak256("ACTION_INDEX_MINT");

    function setUp() public {
        h = new LibEqualIndexFeesHarness();
    }

    function test_actionFeeUnits_returnsZeroWhenDisabled() public {
        h.setActionFee(INDEX_ID, ACTION, 123, false);
        assertEq(h.actionFeeUnits(INDEX_ID, ACTION), 0);
    }

    function test_actionFeeUnits_revertsWhenEnabledButZeroAmount() public {
        h.setActionFee(INDEX_ID, ACTION, 0, true);
        vm.expectRevert(abi.encodeWithSelector(IndexActionFeeDisabled.selector, INDEX_ID, ACTION));
        h.actionFeeUnits(INDEX_ID, ACTION);
    }

    function test_actionFeeUnits_returnsAmountWhenEnabled() public {
        h.setActionFee(INDEX_ID, ACTION, 123, true);
        assertEq(h.actionFeeUnits(INDEX_ID, ACTION), 123);
    }
}

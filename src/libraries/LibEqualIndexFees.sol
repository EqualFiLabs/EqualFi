// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "./Types.sol";
import {LibEqualIndex} from "./LibEqualIndex.sol";
import "./Errors.sol";

library LibEqualIndexFees {
    bytes32 internal constant ACTION_INDEX_MINT = keccak256("ACTION_INDEX_MINT");
    bytes32 internal constant ACTION_INDEX_BURN = keccak256("ACTION_INDEX_BURN");
    bytes32 internal constant ACTION_INDEX_FLASH = keccak256("ACTION_INDEX_FLASH");

    function actionFeeUnits(uint256 indexId, bytes32 action) internal view returns (uint256) {
        LibEqualIndex.EqualIndexStorage storage store = LibEqualIndex.s();
        Types.ActionFeeConfig storage cfg = store.actionFees[indexId][action];
        if (!cfg.enabled) {
            return 0;
        }
        uint256 amount = uint256(cfg.amount);
        if (amount == 0) {
            revert IndexActionFeeDisabled(indexId, action);
        }
        return amount;
    }
}

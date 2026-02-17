// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibPoints} from "../libraries/LibPoints.sol";

error Points_ArrayLengthMismatch();
error Points_IndexPositionWeightInvalid();

contract PointsAdminFacet {
    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibAccess.enforceOwnerOrTimelock();
        _validateIndexWeightsForSingleUpdate(actionType, amount);
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function setPointsPerActionBatch(bytes32[] calldata actionTypes, uint256[] calldata amounts) external {
        LibAccess.enforceOwnerOrTimelock();

        uint256 len = actionTypes.length;
        if (len != amounts.length) revert Points_ArrayLengthMismatch();

        (
            uint256 mintPoints,
            uint256 burnPoints,
            uint256 mintPositionPoints,
            uint256 burnPositionPoints,
            bool indexActionsTouched
        ) = _loadProspectiveIndexPoints(actionTypes, amounts);

        if (indexActionsTouched && !_isIndexWeightConfigValid(mintPoints, burnPoints, mintPositionPoints, burnPositionPoints))
        {
            revert Points_IndexPositionWeightInvalid();
        }

        for (uint256 i = 0; i < len; i++) {
            LibPoints.setPointsPerAction(actionTypes[i], amounts[i]);
        }
    }

    function _validateIndexWeightsForSingleUpdate(bytes32 actionType, uint256 amount) internal view {
        if (!_isIndexWeightAction(actionType)) return;

        uint256 mintPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_MINT);
        uint256 burnPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_BURN);
        uint256 mintPositionPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_MINT_POSITION);
        uint256 burnPositionPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_BURN_POSITION);

        if (actionType == LibPoints.ACTION_INDEX_MINT) {
            mintPoints = amount;
        } else if (actionType == LibPoints.ACTION_INDEX_BURN) {
            burnPoints = amount;
        } else if (actionType == LibPoints.ACTION_INDEX_MINT_POSITION) {
            mintPositionPoints = amount;
        } else if (actionType == LibPoints.ACTION_INDEX_BURN_POSITION) {
            burnPositionPoints = amount;
        }

        if (!_isIndexWeightConfigValid(mintPoints, burnPoints, mintPositionPoints, burnPositionPoints)) {
            revert Points_IndexPositionWeightInvalid();
        }
    }

    function _loadProspectiveIndexPoints(bytes32[] calldata actionTypes, uint256[] calldata amounts)
        internal
        view
        returns (
            uint256 mintPoints,
            uint256 burnPoints,
            uint256 mintPositionPoints,
            uint256 burnPositionPoints,
            bool indexActionsTouched
        )
    {
        mintPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_MINT);
        burnPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_BURN);
        mintPositionPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_MINT_POSITION);
        burnPositionPoints = LibPoints.pointsForAction(LibPoints.ACTION_INDEX_BURN_POSITION);

        uint256 len = actionTypes.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 actionType = actionTypes[i];
            uint256 amount = amounts[i];

            if (actionType == LibPoints.ACTION_INDEX_MINT) {
                mintPoints = amount;
                indexActionsTouched = true;
            } else if (actionType == LibPoints.ACTION_INDEX_BURN) {
                burnPoints = amount;
                indexActionsTouched = true;
            } else if (actionType == LibPoints.ACTION_INDEX_MINT_POSITION) {
                mintPositionPoints = amount;
                indexActionsTouched = true;
            } else if (actionType == LibPoints.ACTION_INDEX_BURN_POSITION) {
                burnPositionPoints = amount;
                indexActionsTouched = true;
            }
        }
    }

    function _isIndexWeightConfigValid(
        uint256 mintPoints,
        uint256 burnPoints,
        uint256 mintPositionPoints,
        uint256 burnPositionPoints
    ) internal pure returns (bool) {
        return mintPositionPoints > mintPoints && burnPositionPoints > burnPoints;
    }

    function _isIndexWeightAction(bytes32 actionType) internal pure returns (bool) {
        return actionType == LibPoints.ACTION_INDEX_MINT || actionType == LibPoints.ACTION_INDEX_BURN
            || actionType == LibPoints.ACTION_INDEX_MINT_POSITION || actionType == LibPoints.ACTION_INDEX_BURN_POSITION;
    }
}

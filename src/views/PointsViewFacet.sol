// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPoints} from "../libraries/LibPoints.sol";

contract PointsViewFacet {
    function getPoints(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function getPointsPerAction(bytes32 actionType) external view returns (uint256) {
        return LibPoints.pointsForAction(actionType);
    }

    function getPointsBatch(address[] calldata users) external view returns (uint256[] memory balances) {
        uint256 len = users.length;
        balances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            balances[i] = LibPoints.balanceOf(users[i]);
        }
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](3);
        selectorsArr[0] = PointsViewFacet.getPoints.selector;
        selectorsArr[1] = PointsViewFacet.getPointsPerAction.selector;
        selectorsArr[2] = PointsViewFacet.getPointsBatch.selector;
    }
}

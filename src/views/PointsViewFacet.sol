// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPoints} from "../libraries/LibPoints.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";

contract PointsViewFacet {
    function getPoints(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function getPointsByKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.balanceOf(pointsKey);
    }

    function getPointsByPosition(uint256 positionId) external view returns (uint256) {
        return LibPoints.balanceOf(LibPositionHelpers.positionKey(positionId));
    }

    function getPointsEarned(address user) external view returns (uint256) {
        return LibPoints.earnedOf(user);
    }

    function getPointsEarnedByKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.earnedOf(pointsKey);
    }

    function getPointsBurned(address user) external view returns (uint256) {
        return LibPoints.burnedOf(user);
    }

    function getPointsBurnedByKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.burnedOf(pointsKey);
    }

    function getTotalPointsEarned() external view returns (uint256) {
        return LibPoints.totalEarned();
    }

    function getTotalPointsBurned() external view returns (uint256) {
        return LibPoints.totalBurned();
    }

    function getPointsPerAction(bytes32 actionType) external view returns (uint256) {
        return LibPoints.pointsForAction(actionType);
    }

    function getAccrualCooldown(bytes32 actionType) external view returns (uint256) {
        return LibPoints.accrualCooldownForAction(actionType);
    }

    function getDailyPointsCap() external view returns (uint256) {
        return LibPoints.dailyPointsCap();
    }

    function getPointsAccruedToday(address user) external view returns (uint256) {
        return LibPoints.accruedToday(user);
    }

    function getPointsAccruedTodayByKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.accruedToday(pointsKey);
    }

    function getPointsBatch(address[] calldata users) external view returns (uint256[] memory balances) {
        uint256 len = users.length;
        balances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            balances[i] = LibPoints.balanceOf(users[i]);
        }
    }

    function getPointsBatchByKey(bytes32[] calldata pointsKeys) external view returns (uint256[] memory balances) {
        uint256 len = pointsKeys.length;
        balances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            balances[i] = LibPoints.balanceOf(pointsKeys[i]);
        }
    }

    function previewRedeem(uint256 pointsIn) external view returns (uint256 tokenOut) {
        return LibPoints.previewRedemption(pointsIn);
    }

    function getRedemptionConfig()
        external
        view
        returns (
            address token,
            bool enabled,
            uint256 tokensPerPointWad,
            uint256 globalMintCap,
            uint256 totalMinted,
            uint64 epochLengthSecs,
            uint256 epochMintCap,
            uint256 epochMintedCurrent
        )
    {
        token = LibPoints.redemptionToken();
        enabled = LibPoints.redemptionEnabled();
        tokensPerPointWad = LibPoints.redemptionRate();
        globalMintCap = LibPoints.redemptionGlobalMintCap();
        totalMinted = LibPoints.redemptionTotalMinted();
        epochLengthSecs = LibPoints.redemptionEpochLength();
        epochMintCap = LibPoints.redemptionEpochMintCap();
        epochMintedCurrent = LibPoints.redemptionMintedInCurrentEpoch();
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](18);
        selectorsArr[0] = PointsViewFacet.getPoints.selector;
        selectorsArr[1] = PointsViewFacet.getPointsByKey.selector;
        selectorsArr[2] = PointsViewFacet.getPointsByPosition.selector;
        selectorsArr[3] = PointsViewFacet.getPointsEarned.selector;
        selectorsArr[4] = PointsViewFacet.getPointsEarnedByKey.selector;
        selectorsArr[5] = PointsViewFacet.getPointsBurned.selector;
        selectorsArr[6] = PointsViewFacet.getPointsBurnedByKey.selector;
        selectorsArr[7] = PointsViewFacet.getTotalPointsEarned.selector;
        selectorsArr[8] = PointsViewFacet.getTotalPointsBurned.selector;
        selectorsArr[9] = PointsViewFacet.getPointsPerAction.selector;
        selectorsArr[10] = PointsViewFacet.getPointsBatch.selector;
        selectorsArr[11] = PointsViewFacet.getPointsBatchByKey.selector;
        selectorsArr[12] = PointsViewFacet.getDailyPointsCap.selector;
        selectorsArr[13] = PointsViewFacet.getPointsAccruedToday.selector;
        selectorsArr[14] = PointsViewFacet.getPointsAccruedTodayByKey.selector;
        selectorsArr[15] = PointsViewFacet.getAccrualCooldown.selector;
        selectorsArr[16] = PointsViewFacet.previewRedeem.selector;
        selectorsArr[17] = PointsViewFacet.getRedemptionConfig.selector;
    }
}

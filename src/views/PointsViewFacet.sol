// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPoints} from "../libraries/LibPoints.sol";

contract PointsViewFacet {
    function getPoints(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function getPointsEarned(address user) external view returns (uint256) {
        return LibPoints.earnedOf(user);
    }

    function getPointsBurned(address user) external view returns (uint256) {
        return LibPoints.burnedOf(user);
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

    function getPointsBatch(address[] calldata users) external view returns (uint256[] memory balances) {
        uint256 len = users.length;
        balances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            balances[i] = LibPoints.balanceOf(users[i]);
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
        selectorsArr = new bytes4[](12);
        selectorsArr[0] = PointsViewFacet.getPoints.selector;
        selectorsArr[1] = PointsViewFacet.getPointsEarned.selector;
        selectorsArr[2] = PointsViewFacet.getPointsBurned.selector;
        selectorsArr[3] = PointsViewFacet.getTotalPointsEarned.selector;
        selectorsArr[4] = PointsViewFacet.getTotalPointsBurned.selector;
        selectorsArr[5] = PointsViewFacet.getPointsPerAction.selector;
        selectorsArr[6] = PointsViewFacet.getPointsBatch.selector;
        selectorsArr[7] = PointsViewFacet.getDailyPointsCap.selector;
        selectorsArr[8] = PointsViewFacet.getPointsAccruedToday.selector;
        selectorsArr[9] = PointsViewFacet.getAccrualCooldown.selector;
        selectorsArr[10] = PointsViewFacet.previewRedeem.selector;
        selectorsArr[11] = PointsViewFacet.getRedemptionConfig.selector;
    }
}

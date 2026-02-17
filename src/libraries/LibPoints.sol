// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

library LibPoints {
    bytes32 internal constant STORAGE_POSITION = keccak256("equallend.points.storage");

    bytes32 internal constant ACTION_DEPOSIT = keccak256("POINTS_DEPOSIT");
    bytes32 internal constant ACTION_BORROW = keccak256("POINTS_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("POINTS_REPAY");
    bytes32 internal constant ACTION_FLASH_LOAN = keccak256("POINTS_FLASH_LOAN");
    bytes32 internal constant ACTION_DERIVATIVE_CREATE = keccak256("POINTS_DERIVATIVE_CREATE");
    bytes32 internal constant ACTION_DIRECT_POST_OFFER = keccak256("POINTS_DIRECT_POST_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT = keccak256("POINTS_DIRECT_ACCEPT");
    bytes32 internal constant ACTION_ROLLING_PAYMENT = keccak256("POINTS_ROLLING_PAYMENT");
    bytes32 internal constant ACTION_SWAP = keccak256("POINTS_SWAP");
    bytes32 internal constant ACTION_INDEX_MINT = keccak256("POINTS_INDEX_MINT");
    bytes32 internal constant ACTION_INDEX_BURN = keccak256("POINTS_INDEX_BURN");
    bytes32 internal constant ACTION_INDEX_MINT_POSITION = keccak256("POINTS_INDEX_MINT_POSITION");
    bytes32 internal constant ACTION_INDEX_BURN_POSITION = keccak256("POINTS_INDEX_BURN_POSITION");

    struct PointsStorage {
        mapping(address => uint256) balances;
        mapping(bytes32 => uint256) pointsPerAction;
    }

    event PointsAccrued(address indexed user, bytes32 indexed actionType, uint256 amount);
    event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);

    function s() internal pure returns (PointsStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            ps.slot := slot
        }
    }

    function accrue(address user, bytes32 actionType) internal {
        PointsStorage storage ps = s();
        uint256 points = ps.pointsPerAction[actionType];
        if (points == 0) return;

        ps.balances[user] += points;
        emit PointsAccrued(user, actionType, points);
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) internal {
        s().pointsPerAction[actionType] = amount;
        emit PointsPerActionUpdated(actionType, amount);
    }

    function balanceOf(address user) internal view returns (uint256) {
        return s().balances[user];
    }

    function pointsForAction(bytes32 actionType) internal view returns (uint256) {
        return s().pointsPerAction[actionType];
    }
}

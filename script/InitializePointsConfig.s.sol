// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PointsAdminFacet} from "../src/admin/PointsAdminFacet.sol";
import {LibPoints} from "../src/libraries/LibPoints.sol";

contract InitializePointsConfigScript is Script {
    uint256 internal constant NON_POSITION_POINTS = 1;
    uint256 internal constant POSITION_POINTS = 2;

    function run() external {
        address diamond = vm.envAddress("DIAMOND");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        (bytes32[] memory actionTypes, uint256[] memory amounts) = _buildConfig();

        vm.startBroadcast(privateKey);
        PointsAdminFacet(diamond).setPointsPerActionBatch(actionTypes, amounts);
        vm.stopBroadcast();
    }

    function _buildConfig() internal pure returns (bytes32[] memory actionTypes, uint256[] memory amounts) {
        actionTypes = new bytes32[](29);
        amounts = new uint256[](29);

        actionTypes[0] = LibPoints.ACTION_DEPOSIT_TO_POSITION;
        actionTypes[1] = LibPoints.ACTION_MINT_POSITION_WITH_DEPOSIT;
        actionTypes[2] = LibPoints.ACTION_BORROW_ROLLING;
        actionTypes[3] = LibPoints.ACTION_BORROW_FIXED;
        actionTypes[4] = LibPoints.ACTION_REPAY_ROLLING;
        actionTypes[5] = LibPoints.ACTION_REPAY_FIXED;
        actionTypes[6] = LibPoints.ACTION_FLASH_LOAN;
        actionTypes[7] = LibPoints.ACTION_DERIVATIVE_CREATE_OPTION;
        actionTypes[8] = LibPoints.ACTION_DERIVATIVE_CREATE_FUTURES;
        actionTypes[9] = LibPoints.ACTION_DERIVATIVE_CREATE_AMM_AUCTION;
        actionTypes[10] = LibPoints.ACTION_DIRECT_POST_LENDER_OFFER;
        actionTypes[11] = LibPoints.ACTION_DIRECT_POST_BORROWER_OFFER;
        actionTypes[12] = LibPoints.ACTION_DIRECT_POST_RATIO_LENDER_OFFER;
        actionTypes[13] = LibPoints.ACTION_DIRECT_POST_RATIO_BORROWER_OFFER;
        actionTypes[14] = LibPoints.ACTION_DIRECT_POST_ROLLING_LENDER_OFFER;
        actionTypes[15] = LibPoints.ACTION_DIRECT_POST_ROLLING_BORROWER_OFFER;
        actionTypes[16] = LibPoints.ACTION_DIRECT_ACCEPT_LENDER_OFFER;
        actionTypes[17] = LibPoints.ACTION_DIRECT_ACCEPT_BORROWER_OFFER;
        actionTypes[18] = LibPoints.ACTION_DIRECT_ACCEPT_RATIO_LENDER_OFFER;
        actionTypes[19] = LibPoints.ACTION_DIRECT_ACCEPT_RATIO_BORROWER_OFFER;
        actionTypes[20] = LibPoints.ACTION_DIRECT_ACCEPT_ROLLING_OFFER;
        actionTypes[21] = LibPoints.ACTION_ROLLING_PAYMENT;
        actionTypes[22] = LibPoints.ACTION_SWAP_AMM_AUCTION;
        actionTypes[23] = LibPoints.ACTION_SWAP_MAM_CURVE;
        actionTypes[24] = LibPoints.ACTION_SWAP_COMMUNITY_AUCTION;
        actionTypes[25] = LibPoints.ACTION_INDEX_MINT;
        actionTypes[26] = LibPoints.ACTION_INDEX_BURN;
        actionTypes[27] = LibPoints.ACTION_INDEX_MINT_POSITION;
        actionTypes[28] = LibPoints.ACTION_INDEX_BURN_POSITION;

        for (uint256 i = 0; i < actionTypes.length; i++) {
            amounts[i] = _pointsForAction(actionTypes[i]);
        }
    }

    function _pointsForAction(bytes32 actionType) internal pure returns (uint256) {
        if (
            actionType == LibPoints.ACTION_FLASH_LOAN || actionType == LibPoints.ACTION_SWAP_AMM_AUCTION
                || actionType == LibPoints.ACTION_SWAP_MAM_CURVE || actionType == LibPoints.ACTION_SWAP_COMMUNITY_AUCTION
                || actionType == LibPoints.ACTION_INDEX_MINT || actionType == LibPoints.ACTION_INDEX_BURN
        ) {
            return NON_POSITION_POINTS;
        }
        return POSITION_POINTS;
    }
}

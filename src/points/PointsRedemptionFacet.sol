// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibPoints} from "../libraries/LibPoints.sol";
import {IPointsEmissionToken} from "../interfaces/IPointsEmissionToken.sol";

error Points_InvalidRedeemRecipient();
error Points_SlippageExceeded();

contract PointsRedemptionFacet is ReentrancyGuardModifiers {
    event PointsRedeemed(address indexed user, address indexed to, uint256 pointsIn, uint256 tokenOut);

    function redeem(uint256 pointsIn, uint256 minTokenOut, address to)
        external
        nonReentrant
        returns (uint256 tokenOut)
    {
        if (to == address(0)) revert Points_InvalidRedeemRecipient();

        (address token, uint256 out) = LibPoints.consumeRedemption(msg.sender, pointsIn);
        if (out < minTokenOut) revert Points_SlippageExceeded();

        IPointsEmissionToken(token).mint(to, out);
        emit PointsRedeemed(msg.sender, to, pointsIn, out);
        return out;
    }
}

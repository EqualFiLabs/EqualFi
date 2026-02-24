// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IPointsEmissionToken {
    function mint(address to, uint256 amount) external;
}

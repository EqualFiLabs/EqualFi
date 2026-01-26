// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";

interface IEqualIndex {
    struct CreateIndexParams {
        string name;
        string symbol;
        address[] assets;
        uint256[] bundleAmounts;
        uint256 flashFeeBps;
        address feeReceiver;
    }

    function createIndex(CreateIndexParams calldata params) external payable returns (uint256 indexId, address token);

    function mint(uint256 indexId, uint256 units, address to) external returns (uint256 minted);

    function burn(uint256 indexId, uint256 units, address to) external returns (uint256[] memory assetsOut);

    function flashLoan(uint256 indexId, uint256 units, address receiver, bytes calldata data) external;

    function setPaused(uint256 indexId, bool paused) external;

    function sweepVaultSurplus(uint256 indexId, address asset) external;

    function getIndex(uint256 indexId) external view returns (LibEqualIndex.Index memory index_);
}

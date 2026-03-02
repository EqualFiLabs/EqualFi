// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IILMPooledFacet {
    function pooledSupply(uint256 positionId, uint256 marketId, uint256 amount) external;

    function pooledWithdraw(uint256 positionId, uint256 marketId, uint256 amount) external returns (uint256 withdrawn);

    function pooledAddCollateral(uint256 positionId, uint256 marketId, uint256 amount) external;

    function pooledRemoveCollateral(uint256 positionId, uint256 marketId, uint256 amount) external;

    function pooledBorrow(uint256 positionId, uint256 marketId, uint256 amount) external;

    function pooledRepay(uint256 positionId, uint256 marketId, uint256 amount) external returns (uint256 repaid);
}

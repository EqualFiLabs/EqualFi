// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IModuleGatewayFacet {
    function encumberPosition(uint256 positionId, uint256 poolId, uint256 moduleId, uint256 amount) external;
    function unencumberPosition(uint256 positionId, uint256 poolId, uint256 moduleId, uint256 amount) external;
    function pokeModuleAum(uint256 positionId, uint256 poolId, uint256 moduleId) external;
}

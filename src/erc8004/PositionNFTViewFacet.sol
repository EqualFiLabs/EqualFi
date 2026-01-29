// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibERC8004Storage} from "../libraries/LibERC8004Storage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";

/// @title PositionNFTViewFacet
/// @notice Read-only helpers for ERC-8004 Position NFT agents
contract PositionNFTViewFacet {
    bytes32 private constant AGENT_WALLET_KEY_HASH = keccak256(bytes("agentWallet"));

    function getAgentWallet(uint256 agentId) external view returns (address) {
        bytes memory data = LibERC8004Storage.s().metadata[agentId][AGENT_WALLET_KEY_HASH];
        if (data.length == 0) {
            return address(0);
        }
        return abi.decode(data, (address));
    }

    function getAgentNonce(uint256 agentId) external view returns (uint256) {
        return LibERC8004Storage.s().agentNonces[agentId];
    }

    function isAgent(uint256 agentId) external view returns (bool) {
        return LibERC8004Storage.s().registered[agentId];
    }

    function getIdentityRegistry() external view returns (address) {
        address registry = LibPositionNFT.s().positionNFTContract;
        if (registry == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return registry;
    }
}

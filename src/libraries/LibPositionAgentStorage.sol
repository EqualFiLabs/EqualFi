// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionNFT} from "./LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "./Errors.sol";
import {PositionAgent_Unauthorized} from "./PositionAgentErrors.sol";

interface PositionNFTLike {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title LibPositionAgentStorage
/// @notice Diamond storage for ERC-6551 position agent integration
library LibPositionAgentStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equal.lend.erc6551.agent.storage");

    struct AgentStorage {
        // Canonical registry addresses
        address erc6551Registry;
        address erc6551Implementation;
        address identityRegistry;

        // Fixed salt for TBA derivation
        bytes32 tbaSalt;

        // Position NFT tokenId => ERC-8004 agentId
        mapping(uint256 => uint256) positionToAgentId;

        // Position NFT tokenId => TBA deployed flag
        mapping(uint256 => bool) tbaDeployed;
    }

    function s() internal pure returns (AgentStorage storage ds) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function requirePositionOwner(uint256 positionTokenId) internal view {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        address owner = PositionNFTLike(nftAddr).ownerOf(positionTokenId);
        if (owner != msg.sender) {
            revert PositionAgent_Unauthorized(msg.sender, positionTokenId);
        }
    }
}

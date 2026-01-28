// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "./LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "./Errors.sol";
import {ERC8004_InvalidAgent, ERC8004_Unauthorized} from "./ERC8004Errors.sol";

/// @title LibERC8004Storage
/// @notice Diamond storage for ERC-8004 Position NFT agent data
library LibERC8004Storage {
    bytes32 internal constant ERC8004_STORAGE_POSITION = keccak256("equal.lend.position.nft.erc8004.storage");

    struct ERC8004Storage {
        // Agent URI storage (agentId => URI string)
        mapping(uint256 => string) agentURIs;

        // Metadata storage (agentId => keccak256(key) => value)
        mapping(uint256 => mapping(bytes32 => bytes)) metadata;

        // Per-agent nonces for replay protection (agentId => nonce)
        mapping(uint256 => uint256) agentNonces;
    }

    function s() internal pure returns (ERC8004Storage storage ds) {
        bytes32 position = ERC8004_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function getMetadataKey(string memory key) internal pure returns (bytes32) {
        return keccak256(bytes(key));
    }

    function requireAuthorized(uint256 agentId) internal view returns (address owner) {
        address registry = LibPositionNFT.s().positionNFTContract;
        if (registry == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        PositionNFT nft = PositionNFT(registry);
        try nft.ownerOf(agentId) returns (address tokenOwner) {
            owner = tokenOwner;
        } catch {
            revert ERC8004_InvalidAgent(agentId);
        }
        if (
            msg.sender != owner &&
            nft.getApproved(agentId) != msg.sender &&
            !nft.isApprovedForAll(owner, msg.sender)
        ) {
            revert ERC8004_Unauthorized(msg.sender, agentId);
        }
    }
}

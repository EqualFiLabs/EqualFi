// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibERC8004Storage} from "../libraries/LibERC8004Storage.sol";
import {
    ERC8004_ReservedMetadataKey
} from "../libraries/ERC8004Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";

/// @title PositionNFTIdentityFacet
/// @notice ERC-8004 identity registry functions for Position NFTs
contract PositionNFTIdentityFacet {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    bytes32 private constant AGENT_WALLET_KEY_HASH = keccak256(bytes("agentWallet"));

    function register() external returns (uint256 agentId) {
        MetadataEntry[] memory empty;
        agentId = _register("", empty);
    }

    function register(string calldata agentURI) external returns (uint256 agentId) {
        MetadataEntry[] memory empty;
        agentId = _register(agentURI, empty);
    }

    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId) {
        agentId = _register(agentURI, metadata);
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        LibERC8004Storage.requireAuthorized(agentId);
        LibERC8004Storage.s().agentURIs[agentId] = newURI;
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    function getAgentURI(uint256 agentId) external view returns (string memory) {
        return LibERC8004Storage.s().agentURIs[agentId];
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        LibERC8004Storage.requireAuthorized(agentId);
        _requireMetadataKeyAllowed(metadataKey);
        _setMetadata(agentId, metadataKey, metadataValue);
    }

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        bytes32 keyHash = LibERC8004Storage.getMetadataKey(metadataKey);
        return LibERC8004Storage.s().metadata[agentId][keyHash];
    }

    function _register(string memory agentURI, MetadataEntry[] memory metadata) internal returns (uint256 agentId) {
        PositionNFT nft = _positionNFT();
        agentId = _mintPosition(nft, msg.sender);

        LibERC8004Storage.ERC8004Storage storage ds = LibERC8004Storage.s();
        ds.agentURIs[agentId] = agentURI;

        uint256 length = metadata.length;
        for (uint256 i = 0; i < length; i++) {
            _requireMetadataKeyAllowed(metadata[i].metadataKey);
            _setMetadata(agentId, metadata[i].metadataKey, metadata[i].metadataValue);
        }

        emit Registered(agentId, agentURI, msg.sender);
    }

    function _setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) internal {
        bytes32 keyHash = LibERC8004Storage.getMetadataKey(metadataKey);
        LibERC8004Storage.s().metadata[agentId][keyHash] = metadataValue;
        emit MetadataSet(agentId, metadataKey, metadataKey, metadataValue);
    }

    function _positionNFT() internal view returns (PositionNFT nft) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        nft = PositionNFT(nftAddr);
    }

    function _mintPosition(PositionNFT nft, address to) internal returns (uint256 tokenId) {
        (bool ok, bytes memory data) = address(nft).call(abi.encodeWithSignature("mint(address)", to));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }

        (ok, data) = address(nft).call(abi.encodeWithSignature("mint(address,uint256)", to, uint256(0)));
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        if (data.length < 32) {
            revert();
        }
        tokenId = abi.decode(data, (uint256));
    }

    function _requireMetadataKeyAllowed(string memory metadataKey) internal pure {
        if (LibERC8004Storage.getMetadataKey(metadataKey) == AGENT_WALLET_KEY_HASH) {
            revert ERC8004_ReservedMetadataKey(metadataKey);
        }
    }
}

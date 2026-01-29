// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";
import {
    PositionAgent_AlreadyRegistered,
    PositionAgent_InvalidAgentOwner
} from "../libraries/PositionAgentErrors.sol";

interface IERC6551Registry {
    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account);
}

interface IERC8004IdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title PositionAgentRegistryFacet
/// @notice Records Position NFT agent registrations after external TBA execution
contract PositionAgentRegistryFacet {
    event AgentRegistered(uint256 indexed positionTokenId, address indexed tbaAddress, uint256 indexed agentId);

    function recordAgentRegistration(uint256 positionTokenId, uint256 agentId) external {
        LibPositionAgentStorage.requirePositionOwner(positionTokenId);

        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        if (ds.positionToAgentId[positionTokenId] != 0) {
            revert PositionAgent_AlreadyRegistered(positionTokenId);
        }

        address tbaAddress = _computeTBAAddress(ds, positionTokenId);
        address registryOwner = IERC8004IdentityRegistry(ds.identityRegistry).ownerOf(agentId);
        if (registryOwner != tbaAddress) {
            revert PositionAgent_InvalidAgentOwner(tbaAddress, registryOwner);
        }

        ds.positionToAgentId[positionTokenId] = agentId;
        emit AgentRegistered(positionTokenId, tbaAddress, agentId);
    }

    function getIdentityRegistry() external view returns (address) {
        return LibPositionAgentStorage.s().identityRegistry;
    }

    function _computeTBAAddress(
        LibPositionAgentStorage.AgentStorage storage ds,
        uint256 positionTokenId
    ) internal view returns (address) {
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = _positionNFTAddress();

        return IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );
    }

    function _positionNFTAddress() internal view virtual returns (address) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return nftAddr;
    }
}

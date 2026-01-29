// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";

interface IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account);

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account);
}

/// @title PositionAgentTBAFacet
/// @notice Computes and deploys ERC-6551 TBAs for Position NFTs
contract PositionAgentTBAFacet {
    event TBADeployed(uint256 indexed positionTokenId, address indexed tbaAddress);

    function computeTBAAddress(uint256 positionTokenId) public view returns (address) {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
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

    function deployTBA(uint256 positionTokenId) external returns (address tbaAddress) {
        LibPositionAgentStorage.requirePositionOwner(positionTokenId);
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        tbaAddress = computeTBAAddress(positionTokenId);

        if (ds.tbaDeployed[positionTokenId]) {
            return tbaAddress;
        }

        if (tbaAddress.code.length > 0) {
            ds.tbaDeployed[positionTokenId] = true;
            return tbaAddress;
        }

        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = _positionNFTAddress();

        address deployed = IERC6551Registry(registry).createAccount(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );

        ds.tbaDeployed[positionTokenId] = true;
        emit TBADeployed(positionTokenId, deployed);
        return deployed;
    }

    function getTBAImplementation() external view returns (address) {
        return LibPositionAgentStorage.s().erc6551Implementation;
    }

    function getERC6551Registry() external view returns (address) {
        return LibPositionAgentStorage.s().erc6551Registry;
    }

    function _positionNFTAddress() internal view virtual returns (address) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return nftAddr;
    }
}

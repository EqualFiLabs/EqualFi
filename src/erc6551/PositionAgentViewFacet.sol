// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {IERC6551Account} from "../interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../interfaces/IERC6551Executable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface IERC6551Registry {
    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account);
}

/// @title PositionAgentViewFacet
/// @notice View functions for ERC-6551 Position Agent integration
contract PositionAgentViewFacet {
    function getTBAAddress(uint256 positionTokenId) external view returns (address) {
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

    function getAgentId(uint256 positionTokenId) external view returns (uint256) {
        return LibPositionAgentStorage.s().positionToAgentId[positionTokenId];
    }

    function isAgentRegistered(uint256 positionTokenId) external view returns (bool) {
        return LibPositionAgentStorage.s().positionToAgentId[positionTokenId] != 0;
    }

    function isTBADeployed(uint256 positionTokenId) external view returns (bool) {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = _positionNFTAddress();

        address tba = IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );
        return tba.code.length > 0;
    }

    function getCanonicalRegistries()
        external
        view
        returns (address erc6551Registry, address erc6551Implementation, address identityRegistry)
    {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        return (ds.erc6551Registry, ds.erc6551Implementation, ds.identityRegistry);
    }

    function getTBAInterfaceSupport(uint256 positionTokenId)
        external
        view
        returns (
            bool supportsAccount,
            bool supportsExecutable,
            bool supportsERC721Receiver,
            bool supportsERC1271
        )
    {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = _positionNFTAddress();

        address tba = IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );

        if (tba.code.length == 0) {
            return (false, false, false, false);
        }

        supportsAccount = _supportsInterface(tba, type(IERC6551Account).interfaceId);
        supportsExecutable = _supportsInterface(tba, type(IERC6551Executable).interfaceId);
        supportsERC721Receiver = _supportsInterface(tba, type(IERC721Receiver).interfaceId);
        supportsERC1271 = _supportsInterface(tba, type(IERC1271).interfaceId);
    }

    function _supportsInterface(address target, bytes4 interfaceId) internal view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, interfaceId)
        );
        if (!ok || data.length < 32) {
            return false;
        }
        return abi.decode(data, (bool));
    }

    function _positionNFTAddress() internal view returns (address) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return nftAddr;
    }
}

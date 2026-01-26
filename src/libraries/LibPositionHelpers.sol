// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibPositionNFT} from "./LibPositionNFT.sol";
import {LibPoolMembership} from "./LibPoolMembership.sol";
import {Types} from "./Types.sol";
import {NotNFTOwner, PoolNotInitialized} from "./Errors.sol";

/// @title LibPositionHelpers
/// @notice Shared helpers for position ownership, pool validation, and membership
library LibPositionHelpers {
    /// @notice Get the app storage
    function appStorage() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    /// @notice Get a pool by ID with validation
    /// @param pid The pool ID
    /// @return The pool data storage reference
    function pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = appStorage().pools[pid];
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
        return p;
    }

    /// @notice Require that the caller owns the specified NFT
    /// @param tokenId The token ID to check ownership for
    function requireOwnership(uint256 tokenId) internal view {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        address owner = nft.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert NotNFTOwner(msg.sender, tokenId);
        }
    }

    /// @notice Get the position key for a token ID
    /// @param tokenId The token ID
    /// @return The position key (bytes32 used in PoolData mappings)
    function positionKey(uint256 tokenId) internal view returns (bytes32) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        return nft.getPositionKey(tokenId);
    }

    /// @notice Derive a system-scoped position key for non-NFT accounts (e.g. protocol treasury).
    /// @dev Prevents address-like keys from being mistaken for user positions.
    function systemPositionKey(address systemAccount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("equal.lend.system.position", systemAccount));
    }

    /// @notice Derive the pool ID from a token ID
    /// @param tokenId The token ID
    /// @return The pool ID associated with the token
    function derivePoolId(uint256 tokenId) internal view returns (uint256) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        return nft.getPoolId(tokenId);
    }

    /// @notice Ensure a position is a member of a pool, optionally auto-joining
    /// @param posKey The position key
    /// @param pid The pool ID
    /// @param allowAutoJoin Whether to auto-join if not already a member
    /// @return alreadyMember True if membership existed before this call
    function ensurePoolMembership(bytes32 posKey, uint256 pid, bool allowAutoJoin)
        internal
        returns (bool alreadyMember)
    {
        return LibPoolMembership._ensurePoolMembership(posKey, pid, allowAutoJoin);
    }
}

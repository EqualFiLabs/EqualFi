// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title ClPositionManager
/// @notice ERC-721 manager for concentrated-liquidity position NFTs.
contract ClPositionManager is ERC721Enumerable {
    error ClPositionManager_OnlyDiamond(address caller);
    error ClPositionManager_InvalidDiamond();

    address public immutable diamond;
    uint256 private _nextTokenId;

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert ClPositionManager_OnlyDiamond(msg.sender);
        _;
    }

    constructor(address diamond_) ERC721("Equalis CL Position", "ECLP") {
        if (diamond_ == address(0)) revert ClPositionManager_InvalidDiamond();
        diamond = diamond_;
        _nextTokenId = 1;
    }

    function mint(address to) external onlyDiamond returns (uint256 tokenId) {
        tokenId = _nextTokenId;
        unchecked {
            _nextTokenId = tokenId + 1;
        }
        _safeMint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyDiamond {
        _burn(tokenId);
    }
}

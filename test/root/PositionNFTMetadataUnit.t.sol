// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockAgentURIDiamond {
    mapping(uint256 => string) private agentURIs;

    function setAgentURI(uint256 agentId, string calldata uri) external {
        agentURIs[agentId] = uri;
    }

    function getAgentURI(uint256 agentId) external view returns (string memory) {
        return agentURIs[agentId];
    }
}

contract RevertingDiamond {
    function getAgentURI(uint256) external pure returns (string memory) {
        revert("diamond call failed");
    }
}

/// @title PositionNFTMetadataUnit
/// @notice Unit tests for PositionNFT tokenURI forwarding
contract PositionNFTMetadataUnit is Test {
    PositionNFT positionNFT;
    MockAgentURIDiamond mockDiamond;

    address user1 = address(0x1);

    uint256 constant POOL_ID = 1;

    function setUp() public {
        positionNFT = new PositionNFT();
        positionNFT.setMinter(address(this));

        mockDiamond = new MockAgentURIDiamond();
        positionNFT.setDiamond(address(mockDiamond));
    }

    /// @notice tokenURI returns the agentURI from the diamond
    function test_TokenURIReturnsAgentURI() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);
        string memory expected = "ipfs://agent-registry/1.json";
        mockDiamond.setAgentURI(tokenId, expected);

        string memory uri = positionNFT.tokenURI(tokenId);
        assertEq(uri, expected, "Token URI should match agentURI");
    }

    /// @notice tokenURI reflects per-token agentURI updates
    function test_TokenURIsAreUniqueForDifferentTokens() public {
        uint256 tokenId1 = positionNFT.mint(user1, POOL_ID);
        uint256 tokenId2 = positionNFT.mint(user1, POOL_ID);

        mockDiamond.setAgentURI(tokenId1, "ipfs://agent-registry/1.json");
        mockDiamond.setAgentURI(tokenId2, "ipfs://agent-registry/2.json");

        assertFalse(
            keccak256(bytes(positionNFT.tokenURI(tokenId1))) ==
                keccak256(bytes(positionNFT.tokenURI(tokenId2))),
            "Different tokens should have different agentURIs"
        );
    }

    /// @notice tokenURI reverts for non-existent token
    function test_TokenURIRevertsForNonExistentToken() public {
        vm.expectRevert();
        positionNFT.tokenURI(999);
    }

    /// @notice tokenURI reverts if diamond call reverts
    function test_TokenURIRevertsWhenDiamondCallReverts() public {
        RevertingDiamond revertingDiamond = new RevertingDiamond();
        positionNFT.setDiamond(address(revertingDiamond));

        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        vm.expectRevert();
        positionNFT.tokenURI(tokenId);
    }

    /// @notice Only the current minter can update the minter address
    function test_SetMinterRespectsMinterOnlyAuth() public {
        address attacker = address(0xAAAA);

        vm.prank(attacker);
        vm.expectRevert(bytes("PositionNFT: unauthorized"));
        positionNFT.setMinter(attacker);
    }

    /// @notice Only the minter can update the diamond address after initialization
    function test_SetDiamondRespectsMinterOnlyAuth() public {
        address attacker = address(0xBBBB);

        vm.prank(attacker);
        vm.expectRevert(bytes("PositionNFT: unauthorized"));
        positionNFT.setDiamond(attacker);
    }
}

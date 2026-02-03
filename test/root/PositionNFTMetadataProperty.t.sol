// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MockAgentURIDiamond {
    mapping(uint256 => string) private agentURIs;

    function setAgentURI(uint256 agentId, string calldata uri) external {
        agentURIs[agentId] = uri;
    }

    function getAgentURI(uint256 agentId) external view returns (string memory) {
        return agentURIs[agentId];
    }
}

/// @title PositionNFTMetadataProperty
/// @notice Property-based tests for PositionNFT tokenURI forwarding
contract PositionNFTMetadataProperty is Test {
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

    /// @notice For any Position NFT, tokenURI should return the registered agentURI
    function testFuzz_TokenURIReturnsRegisteredAgentURI(uint8 numTokens) public {
        vm.assume(numTokens > 0 && numTokens <= 10);

        uint256[] memory tokenIds = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; i++) {
            tokenIds[i] = positionNFT.mint(user1, POOL_ID);
            string memory uri = string(abi.encodePacked("ipfs://agent/", Strings.toString(tokenIds[i])));
            mockDiamond.setAgentURI(tokenIds[i], uri);
        }

        for (uint256 i = 0; i < numTokens; i++) {
            string memory uri = positionNFT.tokenURI(tokenIds[i]);
            string memory expected = string(abi.encodePacked("ipfs://agent/", Strings.toString(tokenIds[i])));
            assertEq(uri, expected, "tokenURI should match agentURI");
        }
    }
}

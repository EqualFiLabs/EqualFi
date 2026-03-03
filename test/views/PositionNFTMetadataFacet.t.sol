// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFTMetadataFacet} from "../../src/views/PositionNFTMetadataFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";

contract MockERC6551RegistryFixedAccount {
    address private accountAddress;

    function setAccount(address account_) external {
        accountAddress = account_;
    }

    function account(address, bytes32, uint256, address, uint256) external view returns (address) {
        return accountAddress;
    }
}

contract MockIdentityRegistryMetadata {
    mapping(uint256 => address) private owners;
    mapping(uint256 => string) private uris;

    function setOwner(uint256 agentId, address owner) external {
        owners[agentId] = owner;
    }

    function setTokenURI(uint256 agentId, string calldata uri) external {
        uris[agentId] = uri;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return owners[agentId];
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        return uris[agentId];
    }
}

contract PositionNFTMetadataFacetHarness is PositionNFTMetadataFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function setAgentConfig(address registry, address implementation, address identityRegistry, bytes32 salt) external {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.erc6551Registry = registry;
        ds.erc6551Implementation = implementation;
        ds.identityRegistry = identityRegistry;
        ds.tbaSalt = salt;
    }

    function setAgentId(uint256 positionTokenId, uint256 agentId) external {
        LibPositionAgentStorage.s().positionToAgentId[positionTokenId] = agentId;
    }
}

contract PositionNFTMetadataFacetTest is Test {
    PositionNFTMetadataFacetHarness internal facet;
    PositionNFT internal nft;
    MockERC6551RegistryFixedAccount internal registry;
    MockIdentityRegistryMetadata internal identity;

    address internal constant USER = address(0xA11CE);
    uint256 internal constant POOL_ID = 1;

    function setUp() public {
        facet = new PositionNFTMetadataFacetHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551RegistryFixedAccount();
        identity = new MockIdentityRegistryMetadata();

        facet.setPositionNFT(address(nft));
        facet.setAgentConfig(address(registry), address(0xBEEF), address(identity), bytes32(0));
    }

    function test_getPositionTokenURI_returnsDataURI() public {
        uint256 tokenId = nft.mint(USER, POOL_ID);

        string memory uri = facet.getPositionTokenURI(tokenId);
        assertGt(bytes(uri).length, 0, "position metadata URI should be non-empty");
        assertEq(_prefix(uri, 29), "data:application/json;base64,", "expected JSON data URI");
    }

    function test_getAgentTokenURI_returnsCanonicalURI_whenLinked() public {
        uint256 tokenId = nft.mint(USER, POOL_ID);
        uint256 agentId = 77;
        address expectedTba = address(0x123456);
        string memory expectedURI = "ipfs://erc8004/77.json";

        registry.setAccount(expectedTba);
        facet.setAgentId(tokenId, agentId);
        identity.setOwner(agentId, expectedTba);
        identity.setTokenURI(agentId, expectedURI);

        assertEq(facet.getAgentIdOf(tokenId), agentId, "agentId mapping mismatch");
        assertTrue(facet.isAgentLinked(tokenId), "agent should be linked");
        assertEq(facet.getAgentTokenURI(tokenId), expectedURI, "canonical ERC-8004 URI mismatch");
    }

    function test_getAgentTokenURI_returnsEmpty_whenUnregistered() public {
        uint256 tokenId = nft.mint(USER, POOL_ID);

        assertEq(facet.getAgentIdOf(tokenId), 0, "agentId should default to zero");
        assertFalse(facet.isAgentLinked(tokenId), "unregistered position should not be linked");
        assertEq(facet.getAgentTokenURI(tokenId), "", "agent URI should be empty when unregistered");
    }

    function test_getAgentTokenURI_returnsEmpty_whenOwnershipMismatch() public {
        uint256 tokenId = nft.mint(USER, POOL_ID);
        uint256 agentId = 88;
        address expectedTba = address(0x123456);
        address wrongOwner = address(0x999999);

        registry.setAccount(expectedTba);
        facet.setAgentId(tokenId, agentId);
        identity.setOwner(agentId, wrongOwner);
        identity.setTokenURI(agentId, "ipfs://erc8004/88.json");

        assertFalse(facet.isAgentLinked(tokenId), "ownership mismatch must invalidate link");
        assertEq(facet.getAgentTokenURI(tokenId), "", "agent URI should be empty when link is invalid");
    }

    function test_agentViews_revertForNonexistentPositionToken() public {
        vm.expectRevert();
        facet.getAgentIdOf(999);

        vm.expectRevert();
        facet.isAgentLinked(999);

        vm.expectRevert();
        facet.getAgentTokenURI(999);
    }

    function test_selectors_includePositionAndAgentMetadataViews() public {
        bytes4[] memory selectors = facet.selectors();
        assertEq(selectors.length, 5, "selector count mismatch");
        assertEq(selectors[0], PositionNFTMetadataFacet.getPositionTokenURI.selector);
        assertEq(selectors[1], PositionNFTMetadataFacet.getAgentTokenURI.selector);
        assertEq(selectors[2], PositionNFTMetadataFacet.getAgentIdOf.selector);
        assertEq(selectors[3], PositionNFTMetadataFacet.isAgentLinked.selector);
        assertEq(selectors[4], PositionNFTMetadataFacet.tokenImageURI.selector);
    }

    function _prefix(string memory value, uint256 len) internal pure returns (string memory) {
        bytes memory data = bytes(value);
        if (data.length <= len) {
            return value;
        }

        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[i];
        }
        return string(out);
    }
}

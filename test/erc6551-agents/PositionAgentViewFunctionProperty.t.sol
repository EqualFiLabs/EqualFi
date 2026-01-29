// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentViewFacet} from "../../src/erc6551/PositionAgentViewFacet.sol";

contract MockERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account) {
        assembly {
            pop(chainId)
            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            let computed := keccak256(0x00, 0x55)

            if iszero(extcodesize(computed)) {
                let deployed := create2(0, 0x55, 0xb7, salt)
                if iszero(deployed) {
                    mstore(0x00, 0x20188a59)
                    revert(0x1c, 0x04)
                }
                mstore(0x6c, deployed)
                return(0x6c, 0x20)
            }

            mstore(0x00, shr(96, shl(96, computed)))
            return(0x00, 0x20)
        }
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account) {
        assembly {
            pop(chainId)
            pop(tokenContract)
            pop(tokenId)

            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            mstore(0x00, shr(96, shl(96, keccak256(0x00, 0x55))))
            return(0x00, 0x20)
        }
    }
}

contract MockERC6551Account {
    receive() external payable {}
}

contract PositionAgentViewFacetHarness is PositionAgentViewFacet {
    function setConfig(address registry, address implementation, address identityRegistry, bytes32 salt) external {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.erc6551Registry = registry;
        ds.erc6551Implementation = implementation;
        ds.identityRegistry = identityRegistry;
        ds.tbaSalt = salt;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function setAgentId(uint256 positionTokenId, uint256 agentId) external {
        LibPositionAgentStorage.s().positionToAgentId[positionTokenId] = agentId;
    }
}

/// @notice Property-based tests for view function consistency
/// forge-config: default.fuzz.runs = 100
contract PositionAgentViewFunctionPropertyTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockERC6551Account private implementation;
    PositionAgentViewFacetHarness private facet;

    function setUp() public {
        nft = new PositionNFT();
        registry = new MockERC6551Registry();
        implementation = new MockERC6551Account();
        facet = new PositionAgentViewFacetHarness();

        facet.setPositionNFT(address(nft));
        facet.setConfig(address(registry), address(implementation), address(0), bytes32(0));
    }

    /// @notice **Feature: erc6551-position-agents, Property 8: View Function Consistency**
    /// @notice View helpers should reflect underlying storage and computed TBA state
    /// @notice **Validates: Requirements 8.2, 8.3, 8.4**
    function testProperty_ViewFunctionConsistency(uint256 tokenId, uint256 agentId) public {
        tokenId = bound(tokenId, 1, 1_000_000);
        agentId = bound(agentId, 1, type(uint256).max - 1);

        address expectedTba = registry.account(
            address(implementation),
            bytes32(0),
            block.chainid,
            address(nft),
            tokenId
        );

        assertEq(facet.getTBAAddress(tokenId), expectedTba, "getTBAAddress should compute registry account");
        assertEq(facet.getAgentId(tokenId), 0, "default agentId should be 0");
        assertFalse(facet.isAgentRegistered(tokenId), "isAgentRegistered should be false before set");
        assertFalse(facet.isTBADeployed(tokenId), "isTBADeployed should be false before deployment");

        facet.setAgentId(tokenId, agentId);
        assertEq(facet.getAgentId(tokenId), agentId, "getAgentId should return stored mapping");
        assertTrue(facet.isAgentRegistered(tokenId), "isAgentRegistered should be true after set");

        registry.createAccount(
            address(implementation),
            bytes32(0),
            block.chainid,
            address(nft),
            tokenId
        );
        assertTrue(facet.isTBADeployed(tokenId), "isTBADeployed should be true after deployment");

        (address reg, address impl, address identity) = facet.getCanonicalRegistries();
        assertEq(reg, address(registry), "getCanonicalRegistries registry mismatch");
        assertEq(impl, address(implementation), "getCanonicalRegistries implementation mismatch");
        assertEq(identity, address(0), "getCanonicalRegistries identity mismatch");
    }
}

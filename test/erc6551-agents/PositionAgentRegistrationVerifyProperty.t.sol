// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentRegistryFacet} from "../../src/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgent_InvalidAgentOwner} from "../../src/libraries/PositionAgentErrors.sol";

contract MockERC6551Registry {
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

contract MockIdentityRegistry {
    mapping(uint256 => address) private owners;

    function setOwner(uint256 agentId, address owner) external {
        owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return owners[agentId];
    }
}

contract PositionAgentRegistryFacetHarness is PositionAgentRegistryFacet {
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
}

/// @notice Property-based tests for agent registration verification
/// forge-config: default.fuzz.runs = 100
contract PositionAgentRegistrationVerifyPropertyTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockERC6551Account private implementation;
    MockIdentityRegistry private identity;
    PositionAgentRegistryFacetHarness private facet;
    address private owner = address(0xA11CE);

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        implementation = new MockERC6551Account();
        identity = new MockIdentityRegistry();
        facet = new PositionAgentRegistryFacetHarness();

        facet.setPositionNFT(address(nft));
        facet.setConfig(address(registry), address(implementation), address(identity), bytes32(0));
    }

    /// @notice **Feature: erc6551-position-agents, Property 6: Agent Registration Verification**
    /// @notice recordAgentRegistration must revert when ownerOf(agentId) != computed TBA
    /// @notice **Validates: Requirements 3.4, 3.6**
    function testProperty_AgentRegistrationVerification(uint256 poolId, uint256 agentId) public {
        poolId = bound(poolId, 1, 1000);
        agentId = bound(agentId, 1, type(uint256).max - 1);

        uint256 tokenId = nft.mint(owner, poolId);

        address tba = registry.account(
            address(implementation),
            bytes32(0),
            block.chainid,
            address(nft),
            tokenId
        );

        address wrongOwner = address(0xBEEF);
        vm.assume(wrongOwner != tba);
        identity.setOwner(agentId, wrongOwner);

        vm.expectRevert(
            abi.encodeWithSelector(PositionAgent_InvalidAgentOwner.selector, tba, wrongOwner)
        );
        vm.prank(owner);
        facet.recordAgentRegistration(tokenId, agentId);
    }
}

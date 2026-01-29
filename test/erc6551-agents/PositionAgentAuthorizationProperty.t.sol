// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentTBAFacet} from "../../src/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "../../src/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgent_Unauthorized} from "../../src/libraries/PositionAgentErrors.sol";
import {DirectError_InvalidPositionNFT} from "../../src/libraries/Errors.sol";

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

contract PositionAgentAuthorizationHarness is PositionAgentTBAFacet, PositionAgentRegistryFacet {
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

    function _positionNFTAddress()
        internal
        view
        override(PositionAgentTBAFacet, PositionAgentRegistryFacet)
        returns (address)
    {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return nftAddr;
    }
}

/// @notice Property-based tests for authorization enforcement
/// forge-config: default.fuzz.runs = 100
contract PositionAgentAuthorizationPropertyTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockERC6551Account private implementation;
    MockIdentityRegistry private identity;
    PositionAgentAuthorizationHarness private facet;

    address private owner = address(0xA11CE);
    address private attacker = address(0xBEEF);

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        implementation = new MockERC6551Account();
        identity = new MockIdentityRegistry();
        facet = new PositionAgentAuthorizationHarness();

        facet.setPositionNFT(address(nft));
        facet.setConfig(address(registry), address(implementation), address(identity), bytes32(0));
    }

    /// @notice **Feature: erc6551-position-agents, Property 5: Authorization Enforcement**
    /// @notice Non-owners cannot deploy TBAs or record agent registrations
    /// @notice **Validates: Requirements 2.1, 3.5, 9.4**
    function testProperty_AuthorizationEnforcement(uint256 poolId, uint256 agentId) public {
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
        identity.setOwner(agentId, tba);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_Unauthorized.selector, attacker, tokenId));
        facet.deployTBA(tokenId);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_Unauthorized.selector, attacker, tokenId));
        facet.recordAgentRegistration(tokenId, agentId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentTBAFacet} from "../../src/erc6551/PositionAgentTBAFacet.sol";

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

contract PositionAgentTBAFacetHarness is PositionAgentTBAFacet {
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

/// @notice Property-based tests for TBA deployment idempotence
/// forge-config: default.fuzz.runs = 100
contract PositionAgentTBADeploymentPropertyTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockERC6551Account private implementation;
    PositionAgentTBAFacetHarness private facet;
    address private owner = address(0xA11CE);

    bytes32 private constant TBA_DEPLOYED_TOPIC = keccak256("TBADeployed(uint256,address)");

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        implementation = new MockERC6551Account();
        facet = new PositionAgentTBAFacetHarness();

        facet.setPositionNFT(address(nft));
        facet.setConfig(address(registry), address(implementation), address(0), bytes32(0));
    }

    /// @notice **Feature: erc6551-position-agents, Property 2: TBA Deployment Idempotence**
    /// @notice Deploying the same TBA twice should return the same address and emit once
    /// @notice **Validates: Requirements 2.1, 2.2, 2.3**
    function testProperty_TBADeploymentIdempotence(uint256 poolId) public {
        poolId = bound(poolId, 1, 1_000_000);

        uint256 tokenId = nft.mint(owner, poolId);
        address expected = facet.computeTBAAddress(tokenId);

        vm.recordLogs();
        vm.prank(owner);
        address first = facet.deployTBA(tokenId);
        vm.prank(owner);
        address second = facet.deployTBA(tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(first, expected, "first deploy should return computed address");
        assertEq(second, expected, "second deploy should return same address");
        assertGt(first.code.length, 0, "TBA should be deployed");

        uint256 deployedEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TBA_DEPLOYED_TOPIC) {
                deployedEvents++;
            }
        }

        assertEq(deployedEvents, 1, "TBADeployed should emit once");
    }
}

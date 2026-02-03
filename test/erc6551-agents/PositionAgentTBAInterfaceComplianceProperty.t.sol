// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentViewFacet} from "../../src/erc6551/PositionAgentViewFacet.sol";
import {IERC165} from "../../src/interfaces/IERC165.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../../src/interfaces/IERC6551Executable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

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

contract MockERC6551Account is IERC165, IERC6551Account, IERC6551Executable, IERC721Receiver, IERC1271 {
    receive() external payable {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1271).interfaceId;
    }

    function token() external pure override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (0, address(0), 0);
    }

    function owner() external pure override returns (address) {
        return address(0);
    }

    function nonce() external pure override returns (uint256) {
        return 0;
    }

    function isValidSigner(address, bytes calldata) external pure override returns (bytes4) {
        return 0x00000000;
    }

    function execute(address, uint256, bytes calldata, uint8) external payable override returns (bytes memory) {
        return "";
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
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
}

/// @notice Property-based tests for TBA interface compliance
/// forge-config: default.fuzz.runs = 100
contract PositionAgentTBAInterfaceCompliancePropertyTest is Test {
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

    /// @notice **Feature: erc6551-position-agents, Property 3: TBA Interface Compliance**
    /// @notice Deployed TBAs should report support for required interfaces via ERC-165
    /// @notice **Validates: Requirements 2.4, 10.1, 10.2, 10.3**
    function testProperty_TBAInterfaceCompliance(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, 1_000_000);

        (bool account, bool executable, bool receiver, bool sig) = facet.getTBAInterfaceSupport(tokenId);
        assertFalse(account || executable || receiver || sig, "undeployed TBA should report no support");

        registry.createAccount(
            address(implementation),
            bytes32(0),
            block.chainid,
            address(nft),
            tokenId
        );

        (account, executable, receiver, sig) = facet.getTBAInterfaceSupport(tokenId);
        assertTrue(account, "IERC6551Account support required");
        assertTrue(executable, "IERC6551Executable support required");
        assertTrue(receiver, "IERC721Receiver support required");
        assertTrue(sig, "IERC1271 support required");
    }
}

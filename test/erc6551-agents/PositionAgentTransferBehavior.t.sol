// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract MockERC6551Account {
    address public tokenContract;
    uint256 public tokenId;

    constructor(address tokenContract_, uint256 tokenId_) {
        tokenContract = tokenContract_;
        tokenId = tokenId_;
    }

    function owner() external view returns (address) {
        try IERC721Owner(tokenContract).ownerOf(tokenId) returns (address currentOwner) {
            return currentOwner;
        } catch {
            return address(0);
        }
    }
}

contract MockERC6551Registry {
    mapping(bytes32 => address) private accounts;

    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account) {
        bytes32 key = keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
        account = accounts[key];
        if (account == address(0)) {
            account = address(new MockERC6551Account(tokenContract, tokenId));
            accounts[key] = account;
        }
        return account;
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address accountAddress) {
        bytes32 key = keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
        return accounts[key];
    }
}

contract MockIdentityRegistry {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public agentWallet;

    function register(uint256 agentId, address tba) external {
        ownerOf[agentId] = tba;
        agentWallet[agentId] = tba;
    }
}

contract PositionAgentTransferIntegrationTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockIdentityRegistry private identity;

    address private owner = address(0xA11CE);
    address private newOwner = address(0xB0B);

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        identity = new MockIdentityRegistry();
    }

    /// @notice **Feature: erc6551-position-agents, Integration: Transfer Behavior**
    /// @notice TBA ownership follows Position NFT transfer; Identity NFT + agentWallet remain bound to TBA
    /// @notice **Validates: Requirements 6.1, 6.2, 6.3**
    function testIntegration_PositionTransferPreservesAgentIdentity() public {
        uint256 tokenId = nft.mint(owner, 1);
        address tba = registry.createAccount(address(0xBEEF), bytes32(0), block.chainid, address(nft), tokenId);
        uint256 agentId = 1;

        identity.register(agentId, tba);

        assertEq(MockERC6551Account(tba).owner(), owner, "TBA owner should be Position NFT owner");
        assertEq(identity.ownerOf(agentId), tba, "Identity NFT should be owned by TBA");
        assertEq(identity.agentWallet(agentId), tba, "agentWallet should be TBA");

        vm.prank(owner);
        nft.safeTransferFrom(owner, newOwner, tokenId);

        assertEq(MockERC6551Account(tba).owner(), newOwner, "TBA owner should transfer with Position NFT");
        assertEq(identity.ownerOf(agentId), tba, "Identity NFT should remain owned by TBA");
        assertEq(identity.agentWallet(agentId), tba, "agentWallet should remain TBA");
    }
}

/// @notice Property-based tests for transfer preserving agent identity
/// forge-config: default.fuzz.runs = 100
contract PositionAgentTransferPropertyTest is Test {
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockIdentityRegistry private identity;

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        identity = new MockIdentityRegistry();
    }

    /// @notice **Feature: erc6551-position-agents, Property 7: Transfer Preserves Agent Identity**
    /// @notice Transferring the Position NFT keeps the TBA and identity bindings intact
    /// @notice **Validates: Requirements 6.1, 6.2, 6.3**
    function testProperty_TransferPreservesAgentIdentity(
        address owner,
        address newOwner,
        uint256 poolId,
        uint256 agentId
    ) public {
        vm.assume(owner != address(0));
        vm.assume(newOwner != address(0));
        vm.assume(owner != newOwner);

        poolId = bound(poolId, 1, 1_000_000);
        agentId = bound(agentId, 1, type(uint256).max - 1);

        uint256 tokenId = nft.mint(owner, poolId);
        address tba = registry.createAccount(address(0xBEEF), bytes32(0), block.chainid, address(nft), tokenId);

        identity.register(agentId, tba);

        assertEq(MockERC6551Account(tba).owner(), owner, "pre-transfer owner mismatch");
        assertEq(identity.ownerOf(agentId), tba, "pre-transfer identity owner mismatch");
        assertEq(identity.agentWallet(agentId), tba, "pre-transfer agentWallet mismatch");

        vm.prank(owner);
        nft.safeTransferFrom(owner, newOwner, tokenId);

        assertEq(MockERC6551Account(tba).owner(), newOwner, "post-transfer owner mismatch");
        assertEq(identity.ownerOf(agentId), tba, "post-transfer identity owner mismatch");
        assertEq(identity.agentWallet(agentId), tba, "post-transfer agentWallet mismatch");
    }
}

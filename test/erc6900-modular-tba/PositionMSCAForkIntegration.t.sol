// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {PositionMSCAImpl} from "../../src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {IERC6551Account} from "@agent-wallet-core/interfaces/IERC6551Account.sol";
import {IERC6900Account} from "@agent-wallet-core/interfaces/IERC6900Account.sol";

interface IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account);

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account);
}

interface IERC8004IdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

/// @notice Fork integration tests against canonical registries.
/// Requires RPC in environment. Optionally set FORK_BLOCK and ERC8004_REGISTRY.
contract PositionMSCAForkIntegrationTest is Test {
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes32 internal constant SALT = bytes32(0);

    function _selectFork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC", string(""));
        if (bytes(rpc).length == 0) {
            return false;
        }

        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        uint256 forkId = blockNumber > 0 ? vm.createFork(rpc, blockNumber) : vm.createFork(rpc);
        vm.selectFork(forkId);
        return true;
    }

    /// @notice End-to-end fork test: ERC-6551 deploy + ERC-8004 register via TBA.
    /// Requires RPC and ERC8004_REGISTRY env vars.
    function testFork_EndToEndRegistryFlow() public {
        if (!_selectFork()) {
            return;
        }

        address identityRegistry = vm.envOr("ERC8004_REGISTRY", address(0));
        if (identityRegistry == address(0) || identityRegistry.code.length == 0) {
            return;
        }

        if (ERC6551_REGISTRY.code.length == 0) {
            return;
        }

        MockPositionNFT nft = new MockPositionNFT();
        address owner = address(0xA11CE);
        uint256 tokenId = nft.mint(owner);

        PositionMSCAImpl implementation = new PositionMSCAImpl(address(0x1234));
        address computed = IERC6551Registry(ERC6551_REGISTRY).account(
            address(implementation),
            SALT,
            block.chainid,
            address(nft),
            tokenId
        );

        address account = IERC6551Registry(ERC6551_REGISTRY).createAccount(
            address(implementation),
            SALT,
            block.chainid,
            address(nft),
            tokenId
        );

        assertEq(account, computed, "registry account mismatch");
        assertGt(account.code.length, 0, "account not deployed");

        (uint256 chainId, address tokenContract, uint256 returnedTokenId) = IERC6551Account(account).token();
        assertEq(chainId, block.chainid, "chainId mismatch");
        assertEq(tokenContract, address(nft), "token contract mismatch");
        assertEq(returnedTokenId, tokenId, "tokenId mismatch");
        assertEq(IERC6551Account(account).owner(), owner, "owner mismatch");

        uint256 registerValue = vm.envOr("ERC8004_REGISTER_VALUE", uint256(0));
        if (registerValue > 0) {
            vm.deal(account, registerValue);
        }

        bytes memory data = abi.encodeWithSelector(
            IERC8004IdentityRegistry.register.selector,
            string("ipfs://example")
        );

        vm.prank(owner);
        bytes memory result = IERC6900Account(account).execute(identityRegistry, registerValue, data);
        uint256 agentId = abi.decode(result, (uint256));

        assertEq(IERC8004IdentityRegistry(identityRegistry).ownerOf(agentId), account, "agent not owned by TBA");

        address newOwner = address(0xB0B);
        vm.prank(owner);
        nft.transferFrom(owner, newOwner, tokenId);
        assertEq(IERC6551Account(account).owner(), newOwner, "owner should follow NFT transfer");
    }
}

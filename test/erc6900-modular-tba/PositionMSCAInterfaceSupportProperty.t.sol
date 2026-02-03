// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "../../src/interfaces/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAccount, IAccountExecute, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {ExecutionManifest, ManifestExecutionFunction, ValidationConfig, ModuleEntity} from "../../src/erc6900/ModuleTypes.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../../src/interfaces/IERC6551Executable.sol";
import {IERC6900Account} from "../../src/erc6900/IERC6900Account.sol";
import {IERC6900ExecutionModule} from "../../src/erc6900/IERC6900ExecutionModule.sol";
import {IERC6900Module} from "../../src/erc6900/IERC6900Module.sol";

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract MockExecutionModule is IERC6900ExecutionModule {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function moduleId() external pure override returns (string memory) {
        return "mock.execution";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        return manifest;
    }
}

contract PositionMSCAInterfaceSupportHarness is PositionMSCA {
    uint256 private _chainId;
    address private _tokenContract;
    uint256 private _tokenId;

    constructor(address entryPoint_) PositionMSCA(entryPoint_) {}

    function setTokenData(uint256 chainId, address tokenContract, uint256 tokenId) external {
        _chainId = chainId;
        _tokenContract = tokenContract;
        _tokenId = tokenId;
    }

    function token() public view override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (_chainId, _tokenContract, _tokenId);
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }
}

/// @notice Property-based tests for interface support tracking
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAInterfaceSupportPropertyTest is Test {
    bytes4 private constant EXEC_SELECTOR_A = bytes4(keccak256("moduleFunctionA()"));
    bytes4 private constant EXEC_SELECTOR_B = bytes4(keccak256("moduleFunctionB()"));

    function _deployAccount(address owner) internal returns (PositionMSCAInterfaceSupportHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAInterfaceSupportHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildManifest(bytes4 selector, bytes4 interfaceId)
        internal
        pure
        returns (ExecutionManifest memory manifest)
    {
        manifest.executionFunctions = new ManifestExecutionFunction[](1);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.interfaceIds = new bytes4[](1);
        manifest.interfaceIds[0] = interfaceId;
    }

    function _isNativeInterface(bytes4 interfaceId) internal pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6900Account).interfaceId ||
            interfaceId == type(IAccount).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC6551Executable).interfaceId ||
            interfaceId == type(IERC1271).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId;
    }

    /// @notice **Feature: erc6900-modular-tba, Property 7: Interface Support Consistency**
    /// @notice supportsInterface should track installed execution module interface IDs
    /// @notice **Validates: Requirements 5.3, 5.4**
    function testProperty_InterfaceSupportConsistency(address owner, bytes4 interfaceId) public {
        vm.assume(owner != address(0));
        vm.assume(!_isNativeInterface(interfaceId));

        PositionMSCAInterfaceSupportHarness account = _deployAccount(owner);
        MockExecutionModule moduleA = new MockExecutionModule();
        MockExecutionModule moduleB = new MockExecutionModule();

        ExecutionManifest memory manifestA = _buildManifest(EXEC_SELECTOR_A, interfaceId);
        ExecutionManifest memory manifestB = _buildManifest(EXEC_SELECTOR_B, interfaceId);

        assertFalse(account.supportsInterface(interfaceId), "interface should be unsupported before install");

        vm.prank(owner);
        account.installExecution(address(moduleA), manifestA, "");
        assertTrue(account.supportsInterface(interfaceId), "interface should be supported after install");

        vm.prank(owner);
        account.installExecution(address(moduleB), manifestB, "");
        assertTrue(account.supportsInterface(interfaceId), "interface should remain supported after second install");

        vm.prank(owner);
        account.uninstallExecution(address(moduleA), manifestA, "");
        assertTrue(account.supportsInterface(interfaceId), "interface should remain supported after one uninstall");

        vm.prank(owner);
        account.uninstallExecution(address(moduleB), manifestB, "");
        assertFalse(account.supportsInterface(interfaceId), "interface should be unsupported after all uninstalls");
    }
}

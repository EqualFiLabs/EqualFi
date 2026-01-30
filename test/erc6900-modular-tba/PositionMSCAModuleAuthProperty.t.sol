// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {
    ExecutionManifest,
    ManifestExecutionFunction,
    ModuleEntity,
    ValidationConfig
} from "../../src/erc6900/ModuleTypes.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";
import {IERC6900ExecutionModule} from "../../src/erc6900/IERC6900ExecutionModule.sol";
import {IERC6900ValidationModule} from "../../src/erc6900/IERC6900ValidationModule.sol";
import {IERC6900Module} from "../../src/erc6900/IERC6900Module.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

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

contract MockValidationModule is IERC6900ValidationModule {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function moduleId() external pure override returns (string memory) {
        return "mock.validation";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function validateUserOp(uint32, PackedUserOperation calldata, bytes32) external pure override returns (uint256) {
        return 0;
    }

    function validateRuntime(address, uint32, address, uint256, bytes calldata, bytes calldata) external pure override {}

    function validateSignature(address, uint32, address, bytes32, bytes calldata) external pure override returns (bytes4) {
        return bytes4(0xffffffff);
    }
}

contract PositionMSCAModuleAuthHarness is PositionMSCA {
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

/// @notice Property-based tests for module authorization
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAModuleAuthPropertyTest is Test {
    bytes4 private constant EXEC_SELECTOR = bytes4(keccak256("doThing()"));

    function _deployAccount(address owner) internal returns (PositionMSCAModuleAuthHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAModuleAuthHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildManifest(bytes4 selector) internal pure returns (ExecutionManifest memory manifest) {
        manifest.executionFunctions = new ManifestExecutionFunction[](1);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
    }

    function _buildValidationConfig(address module, uint32 entityId) internal pure returns (ValidationConfig) {
        return ValidationConfigLib.pack(module, entityId, true, true, true);
    }

    function _singleSelector(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// @notice **Feature: erc6900-modular-tba, Property 20: Module Management Authorization**
    /// @notice Only the Position NFT owner should manage modules
    /// @notice **Validates: Requirements 15.1, 15.3, 15.4**
    function testProperty_ModuleManagementAuthorization(address owner, address attacker) public {
        vm.assume(owner != address(0));
        vm.assume(attacker != address(0));
        vm.assume(owner != attacker);

        PositionMSCAModuleAuthHarness account = _deployAccount(owner);
        MockExecutionModule execModule = new MockExecutionModule();
        MockValidationModule validationModule = new MockValidationModule();

        ExecutionManifest memory manifest = _buildManifest(EXEC_SELECTOR);
        ValidationConfig validationConfig = _buildValidationConfig(address(validationModule), 1);
        bytes4[] memory selectors = _singleSelector(bytes4(keccak256("validate()")));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, attacker));
        account.installExecution(address(execModule), manifest, "");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, attacker));
        account.installValidation(validationConfig, selectors, "", new bytes[](0));

        vm.prank(owner);
        account.installExecution(address(execModule), manifest, "");

        vm.prank(owner);
        account.installValidation(validationConfig, selectors, "", new bytes[](0));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, attacker));
        account.uninstallExecution(address(execModule), manifest, "");

        ModuleEntity validationFunction = ModuleEntityLib.pack(address(validationModule), 1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, attacker));
        account.uninstallValidation(validationFunction, "", new bytes[](0));

        MockExecutionModule execModuleB = new MockExecutionModule();
        vm.prank(address(execModule));
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, address(execModule)));
        account.installExecution(address(execModuleB), manifest, "");
    }

    function testProperty_ModuleSelfModificationReverts() public {
        MockExecutionModule execModule = new MockExecutionModule();
        PositionMSCAModuleAuthHarness selfAccount = _deployAccount(address(execModule));
        ExecutionManifest memory manifest = _buildManifest(EXEC_SELECTOR);
        bytes4[] memory selectors = _singleSelector(bytes4(keccak256("validate()")));

        vm.prank(address(execModule));
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.ModuleSelfModification.selector, address(execModule)));
        selfAccount.installExecution(address(execModule), manifest, "");

        ValidationConfig selfValidationConfig = _buildValidationConfig(address(execModule), 2);
        vm.prank(address(execModule));
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.ModuleSelfModification.selector, address(execModule)));
        selfAccount.installValidation(selfValidationConfig, selectors, "", new bytes[](0));
    }
}

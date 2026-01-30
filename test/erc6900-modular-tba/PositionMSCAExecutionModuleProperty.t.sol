// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {
    ExecutionManifest,
    ManifestExecutionFunction,
    ManifestExecutionHook,
    ModuleEntity,
    ValidationConfig
} from "../../src/erc6900/ModuleTypes.sol";
import {MSCAStorage} from "../../src/erc6900/MSCAStorage.sol";
import {IERC6900Account} from "../../src/erc6900/IERC6900Account.sol";
import {IERC6900ExecutionModule} from "../../src/erc6900/IERC6900ExecutionModule.sol";
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
    bool public installed;
    bool public uninstalled;
    bytes32 public installDataHash;
    bytes32 public uninstallDataHash;

    function onInstall(bytes calldata data) external override {
        installed = true;
        installDataHash = keccak256(data);
    }

    function onUninstall(bytes calldata data) external override {
        uninstalled = true;
        uninstallDataHash = keccak256(data);
    }

    function moduleId() external pure override returns (string memory) {
        return "mock.execution";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function executionManifest() external pure override returns (ExecutionManifest memory) {
        ExecutionManifest memory manifest;
        return manifest;
    }
}

contract PositionMSCAExecutionModuleHarness is PositionMSCA {
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

    function getExecutionData(bytes4 selector) external view returns (address module, bool skip, bool allowGlobal) {
        MSCAStorage.ExecutionData storage data = MSCAStorage.layout().executionData[selector];
        return (data.module, data.skipRuntimeValidation, data.allowGlobalValidation);
    }

    function getExecutionHookCount(bytes4 selector) external view returns (uint256) {
        return MSCAStorage.layout().selectorExecHooks[selector].length;
    }

    function getInterfaceCount(bytes4 interfaceId) external view returns (uint256) {
        return MSCAStorage.layout().supportedInterfaces[interfaceId];
    }

    function isModuleInstalled(address module) external view returns (bool) {
        return MSCAStorage.layout().installedModules[module];
    }

    // Stub implementations for remaining interface requirements
    function executeWithRuntimeValidation(bytes calldata, bytes calldata)
        external
        payable
        override
        returns (bytes memory)
    {
        revert("executeWithRuntimeValidation not implemented");
    }

    function installValidation(ValidationConfig, bytes4[] calldata, bytes calldata, bytes[] calldata)
        external
        override
    {
        revert("installValidation not implemented");
    }

    function uninstallValidation(ModuleEntity, bytes calldata, bytes[] calldata) external override {
        revert("uninstallValidation not implemented");
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure override returns (uint256) {
        return 0;
    }

    function executeUserOp(PackedUserOperation calldata, bytes32) external pure override {
        revert("executeUserOp not implemented");
    }

    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0xffffffff;
    }
}

/// @notice Property-based tests for execution module management
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAExecutionModulePropertyTest is Test {
    function _deployAccount(address owner) internal returns (PositionMSCAExecutionModuleHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAExecutionModuleHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildManifest(bytes4 selectorA, bytes4 selectorB, bytes4 interfaceId)
        internal
        pure
        returns (ExecutionManifest memory manifest)
    {
        manifest.executionFunctions = new ManifestExecutionFunction[](2);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: selectorA,
            skipRuntimeValidation: true,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[1] = ManifestExecutionFunction({
            executionSelector: selectorB,
            skipRuntimeValidation: false,
            allowGlobalValidation: true
        });

        manifest.executionHooks = new ManifestExecutionHook[](2);
        manifest.executionHooks[0] = ManifestExecutionHook({
            executionSelector: selectorA,
            entityId: 11,
            isPreHook: true,
            isPostHook: false
        });
        manifest.executionHooks[1] = ManifestExecutionHook({
            executionSelector: selectorB,
            entityId: 22,
            isPreHook: true,
            isPostHook: true
        });

        manifest.interfaceIds = new bytes4[](1);
        manifest.interfaceIds[0] = interfaceId;
    }

    function _buildManifestSingle(bytes4 selector) internal pure returns (ExecutionManifest memory manifest) {
        manifest.executionFunctions = new ManifestExecutionFunction[](1);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionHooks = new ManifestExecutionHook[](0);
        manifest.interfaceIds = new bytes4[](0);
    }

    function _isNativeSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC6900Account.execute.selector ||
            selector == IERC6900Account.executeBatch.selector ||
            selector == IERC6900Account.executeWithRuntimeValidation.selector ||
            selector == IERC6900Account.installExecution.selector ||
            selector == IERC6900Account.uninstallExecution.selector ||
            selector == IERC6900Account.installValidation.selector ||
            selector == IERC6900Account.uninstallValidation.selector ||
            selector == IERC6900Account.accountId.selector ||
            selector == bytes4(keccak256("owner()")) ||
            selector == bytes4(keccak256("nonce()")) ||
            selector == bytes4(keccak256("entryPoint()"));
    }

    /// @notice **Feature: erc6900-modular-tba, Property 12: Execution Installation Correctness**
    /// @notice installExecution should register execution selectors, hooks, interfaces and call onInstall
    /// @notice **Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7**
    function testProperty_ExecutionInstallationCorrectness(address owner, bytes4 selectorA, bytes4 selectorB, bytes4 interfaceId)
        public
    {
        vm.assume(owner != address(0));
        vm.assume(selectorA != selectorB);
        vm.assume(!_isNativeSelector(selectorA) && !_isNativeSelector(selectorB));

        PositionMSCAExecutionModuleHarness account = _deployAccount(owner);
        MockExecutionModule module = new MockExecutionModule();
        ExecutionManifest memory manifest = _buildManifest(selectorA, selectorB, interfaceId);
        bytes memory installData = abi.encodePacked("install");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC6900Account.ExecutionInstalled(address(module), manifest);
        account.installExecution(address(module), manifest, installData);

        (address moduleA, bool skipA, bool allowA) = account.getExecutionData(selectorA);
        assertEq(moduleA, address(module), "module set for selectorA");
        assertTrue(skipA, "skipRuntimeValidation selectorA");
        assertFalse(allowA, "allowGlobalValidation selectorA");

        (address moduleB, bool skipB, bool allowB) = account.getExecutionData(selectorB);
        assertEq(moduleB, address(module), "module set for selectorB");
        assertFalse(skipB, "skipRuntimeValidation selectorB");
        assertTrue(allowB, "allowGlobalValidation selectorB");

        assertEq(account.getExecutionHookCount(selectorA), 1, "hook count selectorA");
        assertEq(account.getExecutionHookCount(selectorB), 1, "hook count selectorB");
        assertEq(account.getInterfaceCount(interfaceId), 1, "interface count");
        assertTrue(account.isModuleInstalled(address(module)), "module installed flag");
        assertTrue(module.installed(), "module onInstall called");
        assertEq(module.installDataHash(), keccak256(installData), "install data hash");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 13: Execution Selector Collision Prevention**
    /// @notice installExecution should revert on native or existing selector collisions
    /// @notice **Validates: Requirements 9.8, 9.9**
    function testProperty_ExecutionSelectorCollisionPrevention(address owner, bytes4 selector) public {
        vm.assume(owner != address(0));
        PositionMSCAExecutionModuleHarness account = _deployAccount(owner);
        MockExecutionModule module = new MockExecutionModule();

        ExecutionManifest memory nativeManifest = _buildManifestSingle(IERC6900Account.execute.selector);
        vm.prank(owner);
        vm.expectRevert();
        account.installExecution(address(module), nativeManifest, "");

        vm.assume(!_isNativeSelector(selector));
        ExecutionManifest memory manifest = _buildManifestSingle(selector);
        vm.prank(owner);
        account.installExecution(address(module), manifest, "");

        MockExecutionModule module2 = new MockExecutionModule();
        vm.prank(owner);
        vm.expectRevert();
        account.installExecution(address(module2), manifest, "");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 14: Execution Uninstallation Correctness**
    /// @notice uninstallExecution should clear selectors, hooks, interfaces and call onUninstall
    /// @notice **Validates: Requirements 10.1, 10.2, 10.3, 10.4, 10.5, 10.6**
    function testProperty_ExecutionUninstallationCorrectness(address owner, bytes4 selectorA, bytes4 selectorB, bytes4 interfaceId)
        public
    {
        vm.assume(owner != address(0));
        vm.assume(selectorA != selectorB);
        vm.assume(!_isNativeSelector(selectorA) && !_isNativeSelector(selectorB));

        PositionMSCAExecutionModuleHarness account = _deployAccount(owner);
        MockExecutionModule module = new MockExecutionModule();
        ExecutionManifest memory manifest = _buildManifest(selectorA, selectorB, interfaceId);

        vm.prank(owner);
        account.installExecution(address(module), manifest, "install");

        bytes memory uninstallData = abi.encodePacked("uninstall");
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC6900Account.ExecutionUninstalled(address(module), true, manifest);
        account.uninstallExecution(address(module), manifest, uninstallData);

        (address moduleA,,) = account.getExecutionData(selectorA);
        (address moduleB,,) = account.getExecutionData(selectorB);
        assertEq(moduleA, address(0), "selectorA cleared");
        assertEq(moduleB, address(0), "selectorB cleared");
        assertEq(account.getExecutionHookCount(selectorA), 0, "hooks cleared selectorA");
        assertEq(account.getExecutionHookCount(selectorB), 0, "hooks cleared selectorB");
        assertEq(account.getInterfaceCount(interfaceId), 0, "interface count cleared");
        assertFalse(account.isModuleInstalled(address(module)), "module installed flag cleared");
        assertTrue(module.uninstalled(), "module onUninstall called");
        assertEq(module.uninstallDataHash(), keccak256(uninstallData), "uninstall data hash");
    }
}

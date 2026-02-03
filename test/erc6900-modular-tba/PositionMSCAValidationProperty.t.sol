// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {ExecutionManifest, Call, HookConfig, ModuleEntity, ValidationConfig, ValidationFlags} from "../../src/erc6900/ModuleTypes.sol";
import {HookConfigLib} from "../../src/erc6900/HookConfigLib.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";
import {MSCAStorage} from "../../src/erc6900/MSCAStorage.sol";
import {IERC6900Account} from "../../src/erc6900/IERC6900Account.sol";
import {IERC6900ValidationModule} from "../../src/erc6900/IERC6900ValidationModule.sol";
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

contract MockValidationModule is IERC6900ValidationModule {
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

contract MockHookModule is IERC6900Module {
    bool public uninstalled;
    bytes32 public uninstallDataHash;

    function onInstall(bytes calldata) external override {}

    function onUninstall(bytes calldata data) external override {
        uninstalled = true;
        uninstallDataHash = keccak256(data);
    }

    function moduleId() external pure override returns (string memory) {
        return "mock.hook";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }
}

contract PositionMSCAValidationHarness is PositionMSCA {
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

    function getValidationFlags(ModuleEntity validationFunction) external view returns (uint8) {
        return ValidationFlags.unwrap(MSCAStorage.layout().validationData[validationFunction].flags);
    }

    function getValidationSelectorCount(ModuleEntity validationFunction) external view returns (uint256) {
        return MSCAStorage.layout().validationData[validationFunction].selectors.length;
    }

    function getValidationSelector(ModuleEntity validationFunction, uint256 index) external view returns (bytes4) {
        return MSCAStorage.layout().validationData[validationFunction].selectors[index];
    }

    function getValidationHookCounts(ModuleEntity validationFunction) external view returns (uint256, uint256) {
        return (
            MSCAStorage.layout().validationHooks[validationFunction].length,
            MSCAStorage.layout().validationExecHooks[validationFunction].length
        );
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

    function installExecution(address, ExecutionManifest calldata, bytes calldata) external override {
        revert("installExecution not implemented");
    }

    function uninstallExecution(address, ExecutionManifest calldata, bytes calldata) external override {
        revert("uninstallExecution not implemented");
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }
}

/// @notice Property-based tests for validation module management
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAValidationPropertyTest is Test {
    function _deployAccount(address owner) internal returns (PositionMSCAValidationHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAValidationHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildSelectors(bytes4 selectorA, bytes4 selectorB) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = selectorA;
        selectors[1] = selectorB;
    }

    function _buildSingleSelector(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _buildHooks(address validationHook, address execHook) internal pure returns (bytes[] memory hooks) {
        HookConfig hookA = HookConfigLib.pack(validationHook, 11, true, true, false);
        HookConfig hookB = HookConfigLib.pack(execHook, 22, false, true, true);
        hooks = new bytes[](2);
        hooks[0] = abi.encode(hookA);
        hooks[1] = abi.encode(hookB);
    }

    function _buildHookUninstallData() internal pure returns (bytes[] memory hookUninstallData) {
        hookUninstallData = new bytes[](2);
        hookUninstallData[0] = abi.encodePacked("hookA");
        hookUninstallData[1] = abi.encodePacked("hookB");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 9: Validation Installation Correctness**
    /// @notice installValidation should store flags/selectors/hooks and call onInstall
    /// @notice **Validates: Requirements 7.1, 7.2, 7.3, 7.4, 7.5, 7.6**
    function testProperty_ValidationInstallationCorrectness(
        address owner,
        bytes4 selectorA,
        bytes4 selectorB,
        bool isGlobal,
        bool isSignatureValidation,
        bool isUserOpValidation
    ) public {
        vm.assume(owner != address(0));
        PositionMSCAValidationHarness account = _deployAccount(owner);
        MockValidationModule module = new MockValidationModule();
        MockHookModule validationHook = new MockHookModule();
        MockHookModule execHook = new MockHookModule();

        bytes4[] memory selectors = _buildSelectors(selectorA, selectorB);
        ValidationConfig config =
            ValidationConfigLib.pack(address(module), 1, isGlobal, isSignatureValidation, isUserOpValidation);
        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), 1);

        bytes[] memory hooks = _buildHooks(address(validationHook), address(execHook));
        bytes memory installData = abi.encodePacked("install");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC6900Account.ValidationInstalled(address(module), 1);
        account.installValidation(config, selectors, installData, hooks);

        uint8 expectedFlags =
            (isGlobal ? 4 : 0) | (isSignatureValidation ? 2 : 0) | (isUserOpValidation ? 1 : 0);
        assertEq(account.getValidationFlags(validationFunction), expectedFlags, "flags stored");
        assertEq(account.getValidationSelectorCount(validationFunction), 2, "selectors length");
        assertEq(account.getValidationSelector(validationFunction, 0), selectorA, "selector 0");
        assertEq(account.getValidationSelector(validationFunction, 1), selectorB, "selector 1");

        (uint256 validationHookCount, uint256 execHookCount) = account.getValidationHookCounts(validationFunction);
        assertEq(validationHookCount, 1, "validation hook count");
        assertEq(execHookCount, 1, "exec hook count");

        assertTrue(module.installed(), "module onInstall called");
        assertEq(module.installDataHash(), keccak256(installData), "install data hash");
        assertTrue(account.isModuleInstalled(address(module)), "module marked installed");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 10: Validation Installation Authorization**
    /// @notice Non-owner callers must revert on installValidation
    /// @notice **Validates: Requirements 7.7**
    function testProperty_ValidationInstallationAuthorization(address owner, address caller) public {
        vm.assume(owner != address(0));
        vm.assume(caller != owner);
        PositionMSCAValidationHarness account = _deployAccount(owner);
        MockValidationModule module = new MockValidationModule();
        ValidationConfig config = ValidationConfigLib.pack(address(module), 1, false, false, true);
        bytes4[] memory selectors = _buildSingleSelector(bytes4(0x12345678));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.UnauthorizedCaller.selector, caller));
        account.installValidation(config, selectors, "", new bytes[](0));
    }

    /// @notice **Feature: erc6900-modular-tba, Property 11: Validation Uninstallation Correctness**
    /// @notice uninstallValidation should clear configuration and call onUninstall
    /// @notice **Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6**
    function testProperty_ValidationUninstallationCorrectness(address owner) public {
        vm.assume(owner != address(0));
        PositionMSCAValidationHarness account = _deployAccount(owner);
        MockValidationModule module = new MockValidationModule();
        MockHookModule validationHook = new MockHookModule();
        MockHookModule execHook = new MockHookModule();

        bytes4[] memory selectors = _buildSingleSelector(bytes4(0xabcdef01));
        ValidationConfig config = ValidationConfigLib.pack(address(module), 42, true, true, false);
        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), 42);

        bytes[] memory hooks = _buildHooks(address(validationHook), address(execHook));

        vm.prank(owner);
        account.installValidation(config, selectors, "install", hooks);

        bytes[] memory hookUninstallData = _buildHookUninstallData();
        bytes memory uninstallData = abi.encodePacked("uninstall");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC6900Account.ValidationUninstalled(address(module), 42, true);
        account.uninstallValidation(validationFunction, uninstallData, hookUninstallData);

        assertTrue(module.uninstalled(), "module onUninstall called");
        assertEq(module.uninstallDataHash(), keccak256(uninstallData), "module uninstall data hash");
        assertTrue(validationHook.uninstalled(), "validation hook onUninstall called");
        assertEq(validationHook.uninstallDataHash(), keccak256(hookUninstallData[0]), "validation hook data hash");
        assertTrue(execHook.uninstalled(), "exec hook onUninstall called");
        assertEq(execHook.uninstallDataHash(), keccak256(hookUninstallData[1]), "exec hook data hash");

        assertEq(account.getValidationFlags(validationFunction), 0, "flags cleared");
        assertEq(account.getValidationSelectorCount(validationFunction), 0, "selectors cleared");
        (uint256 validationHookCount, uint256 execHookCount) = account.getValidationHookCounts(validationFunction);
        assertEq(validationHookCount, 0, "validation hooks cleared");
        assertEq(execHookCount, 0, "exec hooks cleared");
        assertFalse(account.isModuleInstalled(address(module)), "module cleared from installed map");
    }
}

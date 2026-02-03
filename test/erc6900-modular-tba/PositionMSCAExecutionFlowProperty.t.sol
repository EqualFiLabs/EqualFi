// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {
    ExecutionManifest,
    ManifestExecutionFunction,
    ManifestExecutionHook,
    ModuleEntity,
    ValidationConfig
} from "../../src/erc6900/ModuleTypes.sol";
import {MSCAStorage} from "../../src/erc6900/MSCAStorage.sol";
import {ExecutionFlowLib} from "../../src/erc6900/ExecutionFlowLib.sol";
import {IERC6900ExecutionHookModule} from "../../src/erc6900/IERC6900ExecutionHookModule.sol";
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

interface IExecCounter {
    function execCounter() external view returns (uint256);
}

interface IHookCaller {
    function executeModule(bytes calldata data) external returns (bytes memory);
}

interface IExecCounterSetter {
    function setExecCounter(uint256 value) external;
}

contract ExecutionModuleWithHooks is IERC6900ExecutionModule, IERC6900ExecutionHookModule {
    uint256 public orderIndex;
    mapping(uint256 => uint256) public order;

    function moduleId() external pure override returns (string memory) {
        return "mock.exec.hooks";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        return manifest;
    }

    function preExecutionHook(uint32 entityId, address, uint256, bytes calldata) external override returns (bytes memory) {
        _record(entityId, 1);
        uint256 beforeValue = IExecCounter(msg.sender).execCounter();
        return abi.encode(beforeValue);
    }

    function postExecutionHook(uint32 entityId, bytes calldata preExecHookData) external override {
        _record(entityId, 2);
        uint256 beforeValue = abi.decode(preExecHookData, (uint256));
        uint256 afterValue = IExecCounter(msg.sender).execCounter();
        require(afterValue != beforeValue, "execution not observed");
    }

    function run(uint256 nextValue) external {
        IExecCounterSetter(address(this)).setExecCounter(nextValue);
    }

    function _record(uint32 entityId, uint256 phase) internal {
        order[orderIndex] = uint256(entityId) * 10 + phase;
        orderIndex++;
    }
}

contract RecursiveHookModule is IERC6900ExecutionHookModule {
    function moduleId() external pure override returns (string memory) {
        return "mock.recursive";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function preExecutionHook(uint32, address, uint256, bytes calldata) external override returns (bytes memory) {
        bytes memory callData = abi.encodeWithSignature("run(uint256)", 1);
        IHookCaller(msg.sender).executeModule(callData);
        return "";
    }

    function postExecutionHook(uint32, bytes calldata) external override {}
}

contract PositionMSCAExecutionFlowHarness is PositionMSCA {
    uint256 public execCounter;
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

    function executeModule(bytes calldata data) external payable returns (bytes memory) {
        return _executeModuleWithHooks(data);
    }

    function setExecCounter(uint256 value) external {
        execCounter = value;
    }

    function setHookDepth(uint256 depth) external {
        MSCAStorage.layout().hookDepth = depth;
    }

    function setHookActive(bool active) external {
        MSCAStorage.layout().hookExecutionActive = active;
    }

    function getHookDepth() external view returns (uint256) {
        return MSCAStorage.layout().hookDepth;
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

/// @notice Property-based tests for execution flow and hook protections
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAExecutionFlowPropertyTest is Test {
    uint256 private constant MAX_HOOK_DEPTH = 8;
    function _deployAccount(address owner) internal returns (PositionMSCAExecutionFlowHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAExecutionFlowHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildManifest(bytes4 selector, uint32 entityA, uint32 entityB)
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

        manifest.executionHooks = new ManifestExecutionHook[](2);
        manifest.executionHooks[0] = ManifestExecutionHook({
            executionSelector: selector,
            entityId: entityA,
            isPreHook: true,
            isPostHook: true
        });
        manifest.executionHooks[1] = ManifestExecutionHook({
            executionSelector: selector,
            entityId: entityB,
            isPreHook: true,
            isPostHook: true
        });

        manifest.interfaceIds = new bytes4[](0);
    }

    /// @notice **Feature: erc6900-modular-tba, Property 16: Execution Flow Correctness**
    /// @notice pre hooks run before execution and post hooks after execution with context
    /// @notice **Validates: Requirements 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7**
    function testProperty_ExecutionFlowCorrectness(address owner, uint256 nextValue) public {
        vm.assume(owner != address(0));
        vm.assume(nextValue != 0);
        PositionMSCAExecutionFlowHarness account = _deployAccount(owner);
        ExecutionModuleWithHooks module = new ExecutionModuleWithHooks();

        bytes4 selector = ExecutionModuleWithHooks.run.selector;
        ExecutionManifest memory manifest = _buildManifest(selector, 1, 2);

        vm.prank(owner);
        account.installExecution(address(module), manifest, "");

        bytes memory callData = abi.encodeWithSelector(selector, nextValue);
        vm.prank(owner);
        account.executeModule(callData);

        assertEq(account.execCounter(), nextValue, "execution should update counter");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 17: Hook Ordering Consistency**
    /// @notice pre hooks execute in order, post hooks in reverse
    /// @notice **Validates: Requirements 13.1**
    function testProperty_HookOrdering(address owner, uint256 nextValue) public {
        vm.assume(owner != address(0));
        vm.assume(nextValue != 0);
        PositionMSCAExecutionFlowHarness account = _deployAccount(owner);
        ExecutionModuleWithHooks module = new ExecutionModuleWithHooks();

        bytes4 selector = ExecutionModuleWithHooks.run.selector;
        ExecutionManifest memory manifest = _buildManifest(selector, 1, 2);

        vm.prank(owner);
        account.installExecution(address(module), manifest, "");

        bytes memory callData = abi.encodeWithSelector(selector, nextValue);
        vm.prank(owner);
        account.executeModule(callData);

        assertEq(module.order(0), 11, "pre hook A");
        assertEq(module.order(1), 21, "pre hook B");
        assertEq(module.order(2), 22, "post hook B");
        assertEq(module.order(3), 12, "post hook A");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 18: Hook Depth and Recursion Protection**
    /// @notice recursive hook execution should revert and max depth enforced
    /// @notice **Validates: Requirements 13.2, 13.3**
    function testProperty_HookProtection(address owner) public {
        vm.assume(owner != address(0));
        PositionMSCAExecutionFlowHarness account = _deployAccount(owner);
        RecursiveHookModule module = new RecursiveHookModule();

        bytes4 selector = bytes4(keccak256("run(uint256)"));
        ExecutionManifest memory manifest = _buildManifest(selector, 1, 1);

        vm.prank(owner);
        account.installExecution(address(module), manifest, "");

        bytes memory callData = abi.encodeWithSignature("run(uint256)", 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ExecutionFlowLib.RecursiveHookDetected.selector));
        account.executeModule(callData);

        account.setHookDepth(MAX_HOOK_DEPTH);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ExecutionFlowLib.MaxHookDepthExceeded.selector));
        account.executeModule(callData);
    }
}

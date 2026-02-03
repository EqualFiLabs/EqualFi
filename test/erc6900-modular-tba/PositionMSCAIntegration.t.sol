// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAccount, IAccountExecute, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCAImpl} from "../../src/erc6900/PositionMSCAImpl.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";
import {IERC6900Account} from "../../src/erc6900/IERC6900Account.sol";
import {
    ExecutionManifest,
    ManifestExecutionFunction,
    ManifestExecutionHook,
    HookConfig,
    ModuleEntity,
    ValidationConfig
} from "../../src/erc6900/ModuleTypes.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";
import {HookConfigLib} from "../../src/erc6900/HookConfigLib.sol";
import {IERC6900ExecutionModule} from "../../src/erc6900/IERC6900ExecutionModule.sol";
import {IERC6900ExecutionHookModule} from "../../src/erc6900/IERC6900ExecutionHookModule.sol";
import {IERC6900ValidationModule} from "../../src/erc6900/IERC6900ValidationModule.sol";
import {IERC6900ValidationHookModule} from "../../src/erc6900/IERC6900ValidationHookModule.sol";
import {IERC6900Module} from "../../src/erc6900/IERC6900Module.sol";
import {OwnerValidationModule} from "../../src/erc6900/OwnerValidationModule.sol";

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

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract MockEntryPoint {
    function getUserOpHash(PackedUserOperation calldata userOp) public pure returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce, userOp.callData));
    }

    function handleOp(PackedUserOperation calldata userOp) external {
        bytes32 userOpHash = getUserOpHash(userOp);
        uint256 validation = IAccount(userOp.sender).validateUserOp(userOp, userOpHash, 0);
        require(validation == 0, "validation failed");
        IAccountExecute(userOp.sender).executeUserOp(userOp, userOpHash);
    }
}

contract CounterTarget {
    uint256 public value;

    function setValue(uint256 nextValue) external {
        value = nextValue;
    }
}

contract ExecutionModuleEntryPoint is IERC6900ExecutionModule {
    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function moduleId() external pure override returns (string memory) {
        return "mock.exec.entry";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        return manifest;
    }

    function exec(address target, uint256 value) external {
        CounterTarget(target).setValue(value);
    }
}

contract Recorder {
    mapping(uint32 => uint256) public execCount;
    mapping(uint32 => uint256) public preHookCount;
    mapping(uint32 => uint256) public postHookCount;
    mapping(uint32 => uint256) public validationCount;
    mapping(uint32 => uint256) public validationHookCount;

    function recordExec(uint32 moduleId, uint256) external {
        execCount[moduleId] += 1;
    }

    function recordPreHook(uint32 moduleId) external {
        preHookCount[moduleId] += 1;
    }

    function recordPostHook(uint32 moduleId) external {
        postHookCount[moduleId] += 1;
    }

    function recordValidation(uint32 moduleId) external {
        validationCount[moduleId] += 1;
    }

    function recordValidationHook(uint32 moduleId) external {
        validationHookCount[moduleId] += 1;
    }
}

contract ValidationModule is IERC6900ValidationModule, IERC6900ValidationHookModule {
    Recorder public immutable recorder;
    uint32 public immutable moduleIdValue;

    constructor(Recorder recorder_, uint32 moduleId_) {
        recorder = recorder_;
        moduleIdValue = moduleId_;
    }

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

    function validateRuntime(
        address,
        uint32 entityId,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external override {
        recorder.recordValidation(entityId);
    }

    function validateSignature(address, uint32, address, bytes32, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return bytes4(0xffffffff);
    }

    function preUserOpValidationHook(uint32, PackedUserOperation calldata, bytes32)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function preRuntimeValidationHook(uint32 entityId, address, uint256, bytes calldata, bytes calldata)
        external
        override
    {
        recorder.recordValidationHook(entityId);
    }

    function preSignatureValidationHook(uint32, address, bytes32, bytes calldata) external pure override {}
}

contract ExecutionModuleA is IERC6900ExecutionModule, IERC6900ExecutionHookModule {
    Recorder public immutable recorder;

    constructor(Recorder recorder_) {
        recorder = recorder_;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function moduleId() external pure override returns (string memory) {
        return "mock.exec.a";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        return manifest;
    }

    function execA(uint256 value) external {
        recorder.recordExec(1, value);
    }

    function preExecutionHook(uint32 entityId, address, uint256, bytes calldata)
        external
        override
        returns (bytes memory)
    {
        recorder.recordPreHook(entityId);
        return "";
    }

    function postExecutionHook(uint32 entityId, bytes calldata) external override {
        recorder.recordPostHook(entityId);
    }
}

contract ExecutionModuleB is IERC6900ExecutionModule, IERC6900ExecutionHookModule {
    Recorder public immutable recorder;

    constructor(Recorder recorder_) {
        recorder = recorder_;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function moduleId() external pure override returns (string memory) {
        return "mock.exec.b";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        return manifest;
    }

    function execB(uint256 value) external {
        recorder.recordExec(2, value);
    }

    function preExecutionHook(uint32 entityId, address, uint256, bytes calldata)
        external
        override
        returns (bytes memory)
    {
        recorder.recordPreHook(entityId);
        return "";
    }

    function postExecutionHook(uint32 entityId, bytes calldata) external override {
        recorder.recordPostHook(entityId);
    }
}

contract PositionMSCAIntegrationTest is Test {
    bytes32 private constant SALT = bytes32(0);
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant USER_OP_TYPEHASH = keccak256("UserOp(bytes32 userOpHash)");

    function _deployAccount(
        address owner,
        MockERC6551Registry registry,
        PositionMSCAImpl implementation,
        MockPositionNFT nft
    ) internal returns (address account) {
        uint256 tokenId = nft.mint(owner);
        account = registry.createAccount(address(implementation), SALT, block.chainid, address(nft), tokenId);
    }

    /// @notice **Integration: ERC-6551 Registry Deployment**
    /// @notice Deploy via registry, verify token() and ownership follow NFT
    function testIntegration_ERC6551RegistryDeployment() public {
        MockEntryPoint entryPoint = new MockEntryPoint();
        MockERC6551Registry registry = new MockERC6551Registry();
        PositionMSCAImpl implementation = new PositionMSCAImpl(address(entryPoint));
        MockPositionNFT nft = new MockPositionNFT();

        address owner = address(0xA11CE);
        uint256 tokenId = nft.mint(owner);
        address account = registry.createAccount(address(implementation), SALT, block.chainid, address(nft), tokenId);

        address computed = registry.account(address(implementation), SALT, block.chainid, address(nft), tokenId);
        assertEq(account, computed, "registry account mismatch");

        (uint256 chainId, address tokenContract, uint256 returnedTokenId) = IERC6551Account(account).token();
        assertEq(chainId, block.chainid, "chainId mismatch");
        assertEq(tokenContract, address(nft), "token contract mismatch");
        assertEq(returnedTokenId, tokenId, "tokenId mismatch");
        assertEq(IERC6551Account(account).owner(), owner, "owner mismatch");

        address newOwner = address(0xB0B);
        vm.prank(owner);
        nft.transferFrom(owner, newOwner, tokenId);
        assertEq(IERC6551Account(account).owner(), newOwner, "owner should follow NFT transfer");
    }

    /// @notice **Integration: ERC-4337 EntryPoint Flow**
    /// @notice Submit userOp through EntryPoint and execute
    function testIntegration_EntryPointUserOp() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);

        MockEntryPoint entryPoint = new MockEntryPoint();
        MockERC6551Registry registry = new MockERC6551Registry();
        PositionMSCAImpl implementation = new PositionMSCAImpl(address(entryPoint));
        MockPositionNFT nft = new MockPositionNFT();
        address account = _deployAccount(owner, registry, implementation, nft);

        CounterTarget target = new CounterTarget();
        OwnerValidationModule validationModule = new OwnerValidationModule();
        ExecutionModuleEntryPoint execModule = new ExecutionModuleEntryPoint();

        ValidationConfig config = ValidationConfigLib.pack(address(validationModule), 1, true, true, true);
        vm.prank(owner);
        IERC6900Account(account).installValidation(config, new bytes4[](0), "", new bytes[](0));

        ExecutionManifest memory manifest;
        manifest.executionFunctions = new ManifestExecutionFunction[](1);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: ExecutionModuleEntryPoint.exec.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        vm.prank(owner);
        IERC6900Account(account).installExecution(address(execModule), manifest, "");

        bytes memory callData = abi.encodeWithSelector(ExecutionModuleEntryPoint.exec.selector, address(target), 123);

        PackedUserOperation memory userOp;
        userOp.sender = account;
        userOp.nonce = 0;
        userOp.callData = callData;

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes32 digest = _hashTypedData(account, keccak256(abi.encode(USER_OP_TYPEHASH, userOpHash)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory moduleSig = abi.encodePacked(r, s, v);
        userOp.signature = abi.encode(ModuleEntityLib.pack(address(validationModule), 1), moduleSig);

        entryPoint.handleOp(userOp);
        assertEq(target.value(), 123, "target value should be updated");
    }

    /// @notice **Integration: Multi-module Routing and Hooks**
    /// @notice Install multiple validation/execution modules and verify routing
    function testIntegration_MultiModuleRoutingAndHooks() public {
        address owner = address(0xA11CE);

        MockEntryPoint entryPoint = new MockEntryPoint();
        MockERC6551Registry registry = new MockERC6551Registry();
        PositionMSCAImpl implementation = new PositionMSCAImpl(address(entryPoint));
        MockPositionNFT nft = new MockPositionNFT();
        address account = _deployAccount(owner, registry, implementation, nft);

        Recorder recorder = new Recorder();
        ValidationModule validationA = new ValidationModule(recorder, 1);
        ValidationModule validationB = new ValidationModule(recorder, 2);
        ExecutionModuleA execA = new ExecutionModuleA(recorder);
        ExecutionModuleB execB = new ExecutionModuleB(recorder);

        ValidationConfig configA = ValidationConfigLib.pack(address(validationA), 1, true, false, false);
        ValidationConfig configB = ValidationConfigLib.pack(address(validationB), 2, true, false, false);

        bytes[] memory hooksA = new bytes[](1);
        hooksA[0] = abi.encode(HookConfigLib.pack(address(validationA), 1, true, true, false));
        bytes[] memory hooksB = new bytes[](1);
        hooksB[0] = abi.encode(HookConfigLib.pack(address(validationB), 2, true, true, false));

        vm.prank(owner);
        IERC6900Account(account).installValidation(configA, new bytes4[](0), "", hooksA);
        vm.prank(owner);
        IERC6900Account(account).installValidation(configB, new bytes4[](0), "", hooksB);

        ExecutionManifest memory manifestA;
        manifestA.executionFunctions = new ManifestExecutionFunction[](1);
        manifestA.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: ExecutionModuleA.execA.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifestA.executionHooks = new ManifestExecutionHook[](1);
        manifestA.executionHooks[0] = ManifestExecutionHook({
            executionSelector: ExecutionModuleA.execA.selector,
            entityId: 1,
            isPreHook: true,
            isPostHook: true
        });

        ExecutionManifest memory manifestB;
        manifestB.executionFunctions = new ManifestExecutionFunction[](1);
        manifestB.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: ExecutionModuleB.execB.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifestB.executionHooks = new ManifestExecutionHook[](1);
        manifestB.executionHooks[0] = ManifestExecutionHook({
            executionSelector: ExecutionModuleB.execB.selector,
            entityId: 2,
            isPreHook: true,
            isPostHook: true
        });

        vm.prank(owner);
        IERC6900Account(account).installExecution(address(execA), manifestA, "");
        vm.prank(owner);
        IERC6900Account(account).installExecution(address(execB), manifestB, "");

        bytes memory data = abi.encodeWithSelector(ExecutionModuleA.execA.selector, 11);
        bytes memory authorization = abi.encode(ModuleEntityLib.pack(address(validationA), 1), bytes(""));

        vm.prank(owner);
        IERC6900Account(account).executeWithRuntimeValidation(data, authorization);

        assertEq(recorder.validationHookCount(1), 1, "validation hook A should run");
        assertEq(recorder.validationCount(1), 1, "validation A should run");
        assertEq(recorder.validationHookCount(2), 0, "validation hook B should not run");
        assertEq(recorder.validationCount(2), 0, "validation B should not run");

        vm.prank(owner);
        (bool okB, ) = account.call(abi.encodeWithSelector(ExecutionModuleB.execB.selector, 22));
        assertTrue(okB, "execB call failed");

        assertEq(recorder.execCount(1), 1, "execA should run");
        assertEq(recorder.preHookCount(1), 1, "pre hook A should run");
        assertEq(recorder.postHookCount(1), 1, "post hook A should run");

        assertEq(recorder.execCount(2), 1, "execB should run");
        assertEq(recorder.preHookCount(2), 1, "pre hook B should run");
        assertEq(recorder.postHookCount(2), 1, "post hook B should run");
    }

    function _hashTypedData(address account, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("EqualLend Owner Validation")),
                keccak256(bytes("1.0.0")),
                block.chainid,
                account
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

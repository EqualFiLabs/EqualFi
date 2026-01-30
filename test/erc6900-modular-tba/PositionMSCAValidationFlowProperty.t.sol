// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {HookConfig, ModuleEntity, ValidationConfig} from "../../src/erc6900/ModuleTypes.sol";
import {HookConfigLib} from "../../src/erc6900/HookConfigLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationFlowLib} from "../../src/erc6900/ValidationFlowLib.sol";
import {IERC6900Account} from "../../src/erc6900/IERC6900Account.sol";
import {IERC6900ValidationModule} from "../../src/erc6900/IERC6900ValidationModule.sol";
import {IERC6900ValidationHookModule} from "../../src/erc6900/IERC6900ValidationHookModule.sol";
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

contract MockValidationHook is IERC6900ValidationHookModule {
    bool public userOpCalled;
    bool public runtimeCalled;
    uint256 public userOpValidationData;

    function setUserOpValidationData(uint256 data) external {
        userOpValidationData = data;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}
    function moduleId() external pure override returns (string memory) {
        return "mock.hook";
    }
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function preUserOpValidationHook(uint32, PackedUserOperation calldata, bytes32)
        external
        override
        returns (uint256)
    {
        userOpCalled = true;
        return userOpValidationData;
    }

    function preRuntimeValidationHook(uint32, address, uint256, bytes calldata, bytes calldata) external override {
        runtimeCalled = true;
    }

    function preSignatureValidationHook(uint32, address, bytes32, bytes calldata) external pure override {}
}

contract MockValidationModule is IERC6900ValidationModule {
    address public hook;
    uint256 public userOpValidationData;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function setUserOpValidationData(uint256 data) external {
        userOpValidationData = data;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}
    function moduleId() external pure override returns (string memory) {
        return "mock.validation";
    }
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC6900Module).interfaceId;
    }

    function validateUserOp(uint32, PackedUserOperation calldata, bytes32) external override returns (uint256) {
        require(MockValidationHook(hook).userOpCalled(), "hook not called");
        return userOpValidationData;
    }

    function validateRuntime(address, uint32, address, uint256, bytes calldata, bytes calldata) external override {
        require(MockValidationHook(hook).runtimeCalled(), "hook not called");
    }

    function validateSignature(address, uint32, address, bytes32, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return bytes4(0xffffffff);
    }
}

contract PositionMSCAValidationFlowHarness is PositionMSCA {
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

    function ping() external pure returns (bytes4) {
        return 0x1337c0de;
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }
}

/// @notice Property-based tests for validation flow
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAValidationFlowPropertyTest is Test {
    uint256 private constant SIG_VALIDATION_FAILED = 1;
    function _deployAccount(address owner) internal returns (PositionMSCAValidationFlowHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAValidationFlowHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
    }

    function _buildUserOp(bytes memory callData, bytes memory signature)
        internal
        pure
        returns (PackedUserOperation memory userOp)
    {
        userOp = PackedUserOperation({
            sender: address(0),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    function _buildHooks(address hookModule) internal pure returns (bytes[] memory hooks) {
        HookConfig hookConfig = HookConfigLib.pack(hookModule, 1, true, true, false);
        hooks = new bytes[](1);
        hooks[0] = abi.encode(hookConfig);
    }

    function _packValidationData(address authorizer, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return uint256(uint160(authorizer)) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    /// @notice **Feature: erc6900-modular-tba, Property 15: Validation Flow Correctness**
    /// @notice Hooks run before validation, and time bounds intersect correctly
    /// @notice **Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7**
    function testProperty_ValidationFlowCorrectness(
        address owner,
        uint48 hookAfter,
        uint48 hookUntil,
        uint48 moduleAfter,
        uint48 moduleUntil
    ) public {
        vm.assume(owner != address(0));

        PositionMSCAValidationFlowHarness account = _deployAccount(owner);
        MockValidationHook hook = new MockValidationHook();
        MockValidationModule module = new MockValidationModule();
        module.setHook(address(hook));

        bytes4 selector = bytes4(0x12345678);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;

        ValidationConfig config = ValidationConfigLib.pack(address(module), 1, false, false, true);
        bytes[] memory hooks = _buildHooks(address(hook));

        vm.prank(owner);
        account.installValidation(config, selectors, "", hooks);

        hook.setUserOpValidationData(_packValidationData(address(0), hookUntil, hookAfter));
        module.setUserOpValidationData(_packValidationData(address(0), moduleUntil, moduleAfter));

        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), 1);
        bytes memory moduleSig = bytes("sig");
        bytes memory signature = abi.encode(validationFunction, moduleSig);
        PackedUserOperation memory userOp = _buildUserOp(abi.encodePacked(selector, bytes32(0)), signature);

        uint256 expectedUntil = hookUntil == 0 ? type(uint48).max : hookUntil;
        uint256 expectedUntilB = moduleUntil == 0 ? type(uint48).max : moduleUntil;
        uint48 expectedFinalUntil = expectedUntil < expectedUntilB ? uint48(expectedUntil) : uint48(expectedUntilB);
        uint48 expectedFinalAfter = hookAfter > moduleAfter ? hookAfter : moduleAfter;
        if (expectedFinalUntil == type(uint48).max) {
            expectedFinalUntil = 0;
        }

        vm.prank(address(0x1234));
        uint256 validationData = account.validateUserOp(userOp, bytes32(0), 0);

        assertTrue(hook.userOpCalled(), "hook should be called");
        assertEq(
            validationData,
            _packValidationData(address(0), expectedFinalUntil, expectedFinalAfter),
            "validation data intersection"
        );
    }

    function testProperty_ValidationFlowSelectorCheck(address owner) public {
        vm.assume(owner != address(0));
        PositionMSCAValidationFlowHarness account = _deployAccount(owner);
        MockValidationHook hook = new MockValidationHook();
        MockValidationModule module = new MockValidationModule();
        module.setHook(address(hook));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0xaaaaaaaa);
        ValidationConfig config = ValidationConfigLib.pack(address(module), 1, false, false, true);
        bytes[] memory hooks = new bytes[](0);

        vm.prank(owner);
        account.installValidation(config, selectors, "", hooks);

        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), 1);
        bytes memory signature = abi.encode(validationFunction, bytes("sig"));
        PackedUserOperation memory userOp = _buildUserOp(abi.encodePacked(bytes4(0xbbbbbbbb)), signature);

        vm.prank(address(0x1234));
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidationFlowLib.ValidationNotApplicable.selector,
                validationFunction,
                bytes4(0xbbbbbbbb)
            )
        );
        account.validateUserOp(userOp, bytes32(0), 0);
    }

    function testProperty_ValidationFlowSignatureFailure(address owner) public {
        vm.assume(owner != address(0));
        PositionMSCAValidationFlowHarness account = _deployAccount(owner);
        MockValidationHook hook = new MockValidationHook();
        MockValidationModule module = new MockValidationModule();
        module.setHook(address(hook));

        bytes4 selector = bytes4(0x12345678);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        ValidationConfig config = ValidationConfigLib.pack(address(module), 1, false, false, true);
        bytes[] memory hooks = _buildHooks(address(hook));

        vm.prank(owner);
        account.installValidation(config, selectors, "", hooks);

        hook.setUserOpValidationData(SIG_VALIDATION_FAILED);
        module.setUserOpValidationData(_packValidationData(address(0), 0, 0));

        ModuleEntity validationFunction = ModuleEntityLib.pack(address(module), 1);
        bytes memory signature = abi.encode(validationFunction, bytes("sig"));
        PackedUserOperation memory userOp = _buildUserOp(abi.encodePacked(selector), signature);

        vm.prank(address(0x1234));
        uint256 validationData = account.validateUserOp(userOp, bytes32(0), 0);
        assertEq(validationData, SIG_VALIDATION_FAILED, "signature failure propagated");
    }
}

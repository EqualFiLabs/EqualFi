// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {
    ExecutionManifest,
    ManifestExecutionFunction,
    ModuleEntity,
    ValidationConfig,
    Call
} from "../../src/erc6900/ModuleTypes.sol";
import {ModuleEntityLib} from "../../src/erc6900/ModuleEntityLib.sol";
import {ValidationConfigLib} from "../../src/erc6900/ValidationConfigLib.sol";
import {IERC6900ValidationModule} from "../../src/erc6900/IERC6900ValidationModule.sol";
import {IERC6900Module} from "../../src/erc6900/IERC6900Module.sol";
import {IERC6900ExecutionModule} from "../../src/erc6900/IERC6900ExecutionModule.sol";

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract CounterTarget {
    uint256 public value;

    function setValue(uint256 nextValue) external returns (uint256) {
        value = nextValue;
        return value;
    }

    function add(uint256 amount) external returns (uint256) {
        value += amount;
        return value;
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

contract PositionMSCAStateHarness is PositionMSCA {
    uint256 public value;
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

    function setValue(uint256 nextValue) external {
        value = nextValue;
    }

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }
}

/// @notice Property-based tests for state increment tracking
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAStatePropertyTest is Test {
    bytes4 private constant EXEC_SELECTOR = bytes4(keccak256("moduleFunction()"));

    function _deployAccount(address owner) internal returns (PositionMSCAStateHarness account) {
        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        account = new PositionMSCAStateHarness(address(0x1234));
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

    /// @notice **Feature: erc6900-modular-tba, Property 5: State Increment on Mutation**
    /// @notice mutating operations should increment ERC-6551 state
    /// @notice **Validates: Requirements 3.6**
    function testProperty_StateIncrementOnMutation(address owner, uint256 valueA, uint256 valueB) public {
        vm.assume(owner != address(0));
        vm.assume(valueA <= type(uint256).max - valueB);

        PositionMSCAStateHarness account = _deployAccount(owner);
        CounterTarget counter = new CounterTarget();
        uint256 expected = account.state();

        bytes memory setData = abi.encodeWithSelector(counter.setValue.selector, valueA);
        bytes memory addData = abi.encodeWithSelector(counter.add.selector, valueB);

        vm.prank(owner);
        account.execute(address(counter), 0, setData);
        expected++;
        assertEq(account.state(), expected, "execute should increment state");

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(counter), value: 0, data: setData});
        calls[1] = Call({target: address(counter), value: 0, data: addData});
        vm.prank(owner);
        account.executeBatch(calls);
        expected++;
        assertEq(account.state(), expected, "executeBatch should increment state");

        vm.prank(owner);
        account.execute(address(counter), 0, setData, 0);
        expected++;
        assertEq(account.state(), expected, "IERC6551Executable.execute should increment state");

        MockExecutionModule execModule = new MockExecutionModule();
        ExecutionManifest memory manifest = _buildManifest(EXEC_SELECTOR);
        vm.prank(owner);
        account.installExecution(address(execModule), manifest, "");
        expected++;
        assertEq(account.state(), expected, "installExecution should increment state");

        vm.prank(owner);
        account.uninstallExecution(address(execModule), manifest, "");
        expected++;
        assertEq(account.state(), expected, "uninstallExecution should increment state");

        MockValidationModule validationModule = new MockValidationModule();
        ValidationConfig validationConfig = ValidationConfigLib.pack(address(validationModule), 1, true, false, false);
        vm.prank(owner);
        account.installValidation(validationConfig, new bytes4[](0), "", new bytes[](0));
        expected++;
        assertEq(account.state(), expected, "installValidation should increment state");

        ModuleEntity validationFunction = ModuleEntityLib.pack(address(validationModule), 1);
        bytes memory authorization = abi.encode(validationFunction, bytes(""));
        bytes memory accountCall = abi.encodeWithSelector(account.setValue.selector, valueB);
        vm.prank(owner);
        account.executeWithRuntimeValidation(accountCall, authorization);
        expected++;
        assertEq(account.state(), expected, "executeWithRuntimeValidation should increment state");

        vm.prank(owner);
        account.uninstallValidation(validationFunction, "", new bytes[](0));
        expected++;
        assertEq(account.state(), expected, "uninstallValidation should increment state");
    }
}

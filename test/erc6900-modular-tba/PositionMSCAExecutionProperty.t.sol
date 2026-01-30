// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {ExecutionManifest, Call, ModuleEntity, ValidationConfig} from "../../src/erc6900/ModuleTypes.sol";
import {MSCAStorage} from "../../src/erc6900/MSCAStorage.sol";

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

    function fail() external pure {
        revert("CounterTarget: fail");
    }
}

contract PositionMSCAExecutionHarness is PositionMSCA {
    uint256 private _chainId;
    address private _tokenContract;
    uint256 private _tokenId;

    constructor(address entryPoint_) PositionMSCA(entryPoint_) {}

    function setTokenData(uint256 chainId, address tokenContract, uint256 tokenId) external {
        _chainId = chainId;
        _tokenContract = tokenContract;
        _tokenId = tokenId;
    }

    function setInstalledModule(address module, bool installed) external {
        MSCAStorage.layout().installedModules[module] = installed;
    }

    function token() public view override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (_chainId, _tokenContract, _tokenId);
    }

    // Stub implementations for abstract interface requirements
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

/// @notice Property-based tests for execution correctness
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAExecutionPropertyTest is Test {
    /// @notice **Feature: erc6900-modular-tba, Property 1: Execution Correctness**
    /// @notice execute and executeBatch should perform calls and return results
    /// @notice **Validates: Requirements 1.2, 1.3, 1.5**
    function testProperty_ExecutionCorrectness(address owner, uint256 valueA, uint256 valueB) public {
        vm.assume(owner != address(0));
        vm.assume(valueA <= type(uint256).max - valueB);

        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        PositionMSCAExecutionHarness account = new PositionMSCAExecutionHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);

        CounterTarget counter = new CounterTarget();

        bytes memory setData = abi.encodeWithSelector(counter.setValue.selector, valueA);
        bytes memory addData = abi.encodeWithSelector(counter.add.selector, valueB);
        bytes memory getData = abi.encodeWithSelector(counter.value.selector);

        vm.prank(owner);
        bytes memory setRet = account.execute(address(counter), 0, setData);
        assertEq(abi.decode(setRet, (uint256)), valueA, "setValue result mismatch");

        vm.prank(owner);
        bytes memory addRet = account.execute(address(counter), 0, addData);
        assertEq(abi.decode(addRet, (uint256)), valueA + valueB, "add result mismatch");

        vm.prank(owner);
        bytes memory getRet = account.execute(address(counter), 0, getData);
        assertEq(abi.decode(getRet, (uint256)), valueA + valueB, "value getter mismatch");

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(counter), value: 0, data: abi.encodeWithSelector(counter.setValue.selector, valueB)});
        calls[1] = Call({target: address(counter), value: 0, data: abi.encodeWithSelector(counter.add.selector, valueA)});

        vm.prank(owner);
        bytes[] memory results = account.executeBatch(calls);
        assertEq(results.length, 2, "executeBatch results length");
        assertEq(abi.decode(results[1], (uint256)), valueA + valueB, "batch add result mismatch");
        assertEq(counter.value(), valueA + valueB, "counter value mismatch after batch");
    }

    /// @notice **Feature: erc6900-modular-tba, Property 2: Batch Execution Module Protection**
    /// @notice executeBatch should revert when targeting installed module addresses
    /// @notice **Validates: Requirements 1.4**
    function testProperty_BatchModuleProtection(address owner, address module) public {
        vm.assume(owner != address(0));
        vm.assume(module != address(0));

        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);
        PositionMSCAExecutionHarness account = new PositionMSCAExecutionHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);
        account.setInstalledModule(module, true);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: module, value: 0, data: ""});

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.ModuleTargetNotAllowed.selector, module));
        account.executeBatch(calls);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {NFTBoundMSCA} from "@agent-wallet-core/core/NFTBoundMSCA.sol";
import {ExecutionManifest, Call, ModuleEntity, ValidationConfig} from "@agent-wallet-core/libraries/ModuleTypes.sol";

contract PositionMSCAReceiverHarness is NFTBoundMSCA {
    constructor(address entryPoint_) NFTBoundMSCA(entryPoint_) {}

    function token() public view override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (block.chainid, address(0), 0);
    }

    // Stub implementations for abstract interface requirements
    function execute(address, uint256, bytes calldata) external payable override returns (bytes memory) {
        revert("execute not implemented");
    }

    function executeBatch(Call[] calldata) external payable override returns (bytes[] memory) {
        revert("executeBatch not implemented");
    }

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


    function _owner() internal view override returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid || tokenContract == address(0)) {
            return address(0);
        }

        (bool ok, bytes memory data) =
            tokenContract.staticcall(abi.encodeWithSelector(bytes4(keccak256("ownerOf(uint256)")), tokenId));
        if (!ok || data.length < 32) {
            return address(0);
        }

        return abi.decode(data, (address));
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

    function execute(address, uint256, bytes calldata, uint8) external payable override returns (bytes memory) {
        revert("IERC6551Executable not implemented");
    }
}

/// @notice Property-based tests for ERC-721 receiver acceptance
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAReceiverPropertyTest is Test {
    /// @notice **Feature: erc6900-modular-tba, Property 8: ERC-721 Receiver Acceptance**
    /// @notice Should return ERC721Receiver magic value for any call
    /// @notice **Validates: Requirements 6.2**
    function testProperty_ERC721ReceiverAcceptance(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) public {
        PositionMSCAReceiverHarness account = new PositionMSCAReceiverHarness(address(0x1234));
        bytes4 selector = account.onERC721Received(operator, from, tokenId, data);
        assertEq(
            bytes32(selector),
            bytes32(bytes4(0x150b7a02)),
            "onERC721Received should return magic value"
        );
    }
}

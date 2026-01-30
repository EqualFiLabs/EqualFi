// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";
import {OwnerValidationModule} from "../../src/erc6900/OwnerValidationModule.sol";

contract MockAccount is IERC6551Account {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function setOwner(address newOwner) external {
        _owner = newOwner;
    }

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (block.chainid, address(0xBEEF), 1);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function nonce() external pure returns (uint256) {
        return 0;
    }

    function isValidSigner(address, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @notice Property-based tests for owner validation module
/// forge-config: default.fuzz.runs = 100
contract OwnerValidationModulePropertyTest is Test {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant USER_OP_TYPEHASH = keccak256("UserOp(bytes32 userOpHash)");
    bytes32 private constant MESSAGE_TYPEHASH = keccak256("Message(bytes32 hash)");

    string private constant NAME = "EqualLend Owner Validation";
    string private constant VERSION = "1.0.0";

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    uint256 private constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _hashTypedData(address account, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                block.chainid,
                account
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _buildUserOp(address sender, bytes memory signature)
        internal
        pure
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = sender;
        userOp.signature = signature;
    }

    /// @notice **Feature: erc6900-modular-tba, Property 19: Owner Validation Module Correctness**
    /// @notice Owner signatures should be valid for userOps and ERC-1271, and runtime should require owner
    /// @notice **Validates: Requirements 14.2, 14.3, 14.4**
    function testProperty_OwnerValidationModuleCorrectness(
        uint256 ownerKey,
        uint256 otherKey,
        bytes32 userOpHash,
        bytes32 messageHash
    ) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        otherKey = bound(otherKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != otherKey);

        address owner = vm.addr(ownerKey);
        address other = vm.addr(otherKey);

        MockAccount account = new MockAccount(owner);
        OwnerValidationModule module = new OwnerValidationModule();

        bytes32 userOpDigest = _hashTypedData(address(account), keccak256(abi.encode(USER_OP_TYPEHASH, userOpHash)));
        (uint8 vOwner, bytes32 rOwner, bytes32 sOwner) = vm.sign(ownerKey, userOpDigest);
        bytes memory ownerSig = abi.encodePacked(rOwner, sOwner, vOwner);
        (uint8 vOther, bytes32 rOther, bytes32 sOther) = vm.sign(otherKey, userOpDigest);
        bytes memory otherSig = abi.encodePacked(rOther, sOther, vOther);

        PackedUserOperation memory ownerOp = _buildUserOp(address(account), ownerSig);
        PackedUserOperation memory otherOp = _buildUserOp(address(account), otherSig);

        assertEq(module.validateUserOp(0, ownerOp, userOpHash), 0, "owner userOp should be valid");
        assertEq(module.validateUserOp(0, otherOp, userOpHash), 1, "non-owner userOp should be invalid");

        module.validateRuntime(address(account), 0, owner, 0, "", "");
        vm.expectRevert(abi.encodeWithSelector(OwnerValidationModule.UnauthorizedCaller.selector, other));
        module.validateRuntime(address(account), 0, other, 0, "", "");

        bytes32 messageDigest = _hashTypedData(address(account), keccak256(abi.encode(MESSAGE_TYPEHASH, messageHash)));
        (uint8 vMsgOwner, bytes32 rMsgOwner, bytes32 sMsgOwner) = vm.sign(ownerKey, messageDigest);
        bytes memory ownerMessageSig = abi.encodePacked(rMsgOwner, sMsgOwner, vMsgOwner);
        (uint8 vMsgOther, bytes32 rMsgOther, bytes32 sMsgOther) = vm.sign(otherKey, messageDigest);
        bytes memory otherMessageSig = abi.encodePacked(rMsgOther, sMsgOther, vMsgOther);

        assertEq(
            module.validateSignature(address(account), 0, address(0), messageHash, ownerMessageSig),
            ERC1271_MAGIC,
            "owner signature should be valid"
        );
        assertEq(
            module.validateSignature(address(account), 0, address(0), messageHash, otherMessageSig),
            bytes4(0xffffffff),
            "non-owner signature should be invalid"
        );
        assertEq(
            module.validateSignature(address(account), 0, address(0), messageHash, ""),
            bytes4(0xffffffff),
            "empty signature should be invalid"
        );
    }
}

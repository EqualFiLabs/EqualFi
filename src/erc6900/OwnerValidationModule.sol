// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IERC165} from "../interfaces/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC6551Account} from "../interfaces/IERC6551Account.sol";
import {IERC6900Module} from "./IERC6900Module.sol";
import {IERC6900ValidationModule} from "./IERC6900ValidationModule.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

/// @title OwnerValidationModule
/// @notice Default validation module that validates signatures against the Position NFT owner
contract OwnerValidationModule is IERC6900ValidationModule {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant USER_OP_TYPEHASH = keccak256("UserOp(bytes32 userOpHash)");
    bytes32 internal constant MESSAGE_TYPEHASH = keccak256("Message(bytes32 hash)");

    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    bytes32 internal constant ERC6492_MAGIC_VALUE =
        0x6492649264926492649264926492649264926492649264926492649264926492;
    uint256 internal constant ERC6492_MIN_LENGTH = 192;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    string internal constant NAME = "EqualLend Owner Validation";
    string internal constant VERSION = "1.0.0";

    error UnauthorizedCaller(address caller);

    function onInstall(bytes calldata) external pure override {}

    function onUninstall(bytes calldata) external pure override {}

    function moduleId() external pure override returns (string memory) {
        return "equallend.owner-validation.1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6900Module).interfaceId ||
            interfaceId == type(IERC6900ValidationModule).interfaceId;
    }

    function validateUserOp(uint32, PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        override
        returns (uint256)
    {
        address owner = IERC6551Account(userOp.sender).owner();
        bytes32 digest = _hashTypedData(userOp.sender, keccak256(abi.encode(USER_OP_TYPEHASH, userOpHash)));
        if (!_isValidOwnerSignature(owner, digest, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return 0;
    }

    function validateRuntime(
        address account,
        uint32,
        address sender,
        uint256,
        bytes calldata,
        bytes calldata
    ) external view override {
        address owner = IERC6551Account(account).owner();
        if (sender != owner) {
            revert UnauthorizedCaller(sender);
        }
    }

    function validateSignature(
        address account,
        uint32,
        address,
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        address owner = IERC6551Account(account).owner();
        bytes32 digest = _hashTypedData(account, keccak256(abi.encode(MESSAGE_TYPEHASH, hash)));
        if (_isValidOwnerSignatureView(owner, digest, signature)) {
            return ERC1271_MAGICVALUE;
        }
        return bytes4(0xffffffff);
    }

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

    function _isValidOwnerSignature(address owner, bytes32 digest, bytes calldata signature)
        internal
        returns (bool)
    {
        if (_isERC6492Signature(signature)) {
            if (signature.length < ERC6492_MIN_LENGTH) {
                return false;
            }
            (address factory, bytes memory factoryCalldata, bytes memory innerSig) =
                _decodeERC6492Signature(signature);
            if (owner.code.length > 0) {
                if (_isValidERC1271(owner, digest, innerSig)) {
                    return true;
                }
            }
            if (factory.code.length == 0) {
                return false;
            }
            // ERC-6492 may require deployment side effects, so use call (not staticcall).
            bool ok = _callFactory(factory, factoryCalldata);
            if (!ok) {
                return false;
            }
            return _isValidERC1271(owner, digest, innerSig);
        }

        if (owner.code.length > 0) {
            return _isValidERC1271(owner, digest, signature);
        }

        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(digest, signature);
        return error == ECDSA.RecoverError.NoError && signer == owner;
    }

    function _isValidOwnerSignatureView(address owner, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (_isERC6492Signature(signature)) {
            if (signature.length < ERC6492_MIN_LENGTH) {
                return false;
            }
            (, , bytes memory innerSig) = _decodeERC6492Signature(signature);
            if (owner.code.length > 0) {
                return _isValidERC1271(owner, digest, innerSig);
            }
            return false;
        }

        if (owner.code.length > 0) {
            return _isValidERC1271(owner, digest, signature);
        }

        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(digest, signature);
        return error == ECDSA.RecoverError.NoError && signer == owner;
    }

    function _isValidERC1271(address owner, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        (bool ok, bytes memory data) = owner.staticcall(
            abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
        );
        return ok && data.length == 32 && bytes4(data) == ERC1271_MAGICVALUE;
    }

    function _isERC6492Signature(bytes calldata signature) internal pure returns (bool) {
        if (signature.length < 32) {
            return false;
        }
        bytes32 suffix;
        assembly {
            suffix := calldataload(add(signature.offset, sub(signature.length, 32)))
        }
        return suffix == ERC6492_MAGIC_VALUE;
    }

    function _decodeERC6492Signature(bytes calldata signature)
        internal
        pure
        returns (address factory, bytes memory factoryCalldata, bytes memory innerSig)
    {
        bytes memory wrapped = signature[:signature.length - 32];
        (factory, factoryCalldata, innerSig) = abi.decode(wrapped, (address, bytes, bytes));
    }

    function _callFactory(address factory, bytes memory factoryCalldata) internal returns (bool ok) {
        assembly {
            ok := call(gas(), factory, 0, add(factoryCalldata, 0x20), mload(factoryCalldata), 0, 0)
        }
    }
}

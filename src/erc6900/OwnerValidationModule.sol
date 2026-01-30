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
        view
        override
        returns (uint256)
    {
        address owner = IERC6551Account(userOp.sender).owner();
        bytes32 digest = _hashTypedData(userOp.sender, keccak256(abi.encode(USER_OP_TYPEHASH, userOpHash)));
        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(digest, userOp.signature);
        if (error != ECDSA.RecoverError.NoError || signer != owner) {
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
        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(digest, signature);
        if (error == ECDSA.RecoverError.NoError && signer == owner) {
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
}

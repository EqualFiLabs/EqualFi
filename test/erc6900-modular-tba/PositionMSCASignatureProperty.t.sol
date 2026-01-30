// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

import {PositionMSCA} from "../../src/erc6900/PositionMSCA.sol";
import {ExecutionManifest, Call, ModuleEntity, ValidationConfig} from "../../src/erc6900/ModuleTypes.sol";

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract PositionMSCASignatureHarness is PositionMSCA {
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

    function accountId() external pure override returns (string memory) {
        return "equallend.position-tba.1.0.0";
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure override returns (uint256) {
        return 0;
    }

    function executeUserOp(PackedUserOperation calldata, bytes32) external pure override {
        revert("executeUserOp not implemented");
    }
}

/// @notice Property-based tests for ERC-1271 signature validation
/// forge-config: default.fuzz.runs = 100
contract PositionMSCASignaturePropertyTest is Test {
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    uint256 private constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice **Feature: erc6900-modular-tba, Property 6: Signature Validation Correctness**
    /// @notice Owner signatures should be valid and non-owner signatures invalid
    /// @notice **Validates: Requirements 4.2, 4.3, 4.4**
    function testProperty_SignatureValidationCorrectness(uint256 ownerKey, uint256 otherKey, bytes32 digest) public {
        ownerKey = bound(ownerKey, 1, SECP256K1_N - 1);
        otherKey = bound(otherKey, 1, SECP256K1_N - 1);
        vm.assume(ownerKey != otherKey);

        address owner = vm.addr(ownerKey);

        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);

        PositionMSCASignatureHarness account = new PositionMSCASignatureHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);

        (uint8 vOwner, bytes32 rOwner, bytes32 sOwner) = vm.sign(ownerKey, digest);
        bytes memory ownerSig = abi.encodePacked(rOwner, sOwner, vOwner);

        (uint8 vOther, bytes32 rOther, bytes32 sOther) = vm.sign(otherKey, digest);
        bytes memory otherSig = abi.encodePacked(rOther, sOther, vOther);

        assertEq(account.isValidSignature(digest, ownerSig), ERC1271_MAGIC, "owner signature should be valid");
        assertEq(account.isValidSignature(digest, otherSig), bytes4(0xffffffff), "non-owner signature should be invalid");
        assertEq(
            account.isValidSignature(digest, ""),
            bytes4(0xffffffff),
            "empty signature should be invalid"
        );
    }
}

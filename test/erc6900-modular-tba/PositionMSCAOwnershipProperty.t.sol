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

contract PositionMSCAHarness is PositionMSCA {
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

    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0xffffffff;
    }

    function execute(address, uint256, bytes calldata, uint8) external payable override returns (bytes memory) {
        revert("IERC6551Executable not implemented");
    }
}

/// @notice Property-based tests for ownership follows NFT
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAOwnershipPropertyTest is Test {
    bytes4 private constant ERC6551_MAGIC = 0x523e3260;

    /// @notice **Feature: erc6900-modular-tba, Property 3: Ownership Follows NFT**
    /// @notice Ownership changes should update valid signer
    /// @notice **Validates: Requirements 3.3, 3.5**
    function testProperty_OwnershipFollowsNFT(address owner, address newOwner) public {
        vm.assume(owner != address(0));
        vm.assume(newOwner != address(0));
        vm.assume(owner != newOwner);

        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);

        PositionMSCAHarness account = new PositionMSCAHarness(address(0x1234));
        account.setTokenData(block.chainid, address(nft), tokenId);

        assertEq(bytes32(account.isValidSigner(owner, "")), bytes32(ERC6551_MAGIC), "owner should be valid signer");
        assertEq(
            bytes32(account.isValidSigner(newOwner, "")),
            bytes32(bytes4(0xffffffff)),
            "new owner should be invalid before transfer"
        );

        vm.prank(owner);
        nft.transferFrom(owner, newOwner, tokenId);

        assertEq(bytes32(account.isValidSigner(newOwner, "")), bytes32(ERC6551_MAGIC), "new owner should be valid signer");
        assertEq(
            bytes32(account.isValidSigner(owner, "")),
            bytes32(bytes4(0xffffffff)),
            "old owner should be invalid"
        );
    }
}

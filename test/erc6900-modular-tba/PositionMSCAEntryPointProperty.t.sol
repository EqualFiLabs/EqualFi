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

contract PositionMSCAEntryPointHarness is PositionMSCA {
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

    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0xffffffff;
    }
}

/// @notice Property-based tests for EntryPoint validation behavior
/// forge-config: default.fuzz.runs = 100
contract PositionMSCAEntryPointPropertyTest is Test {
    function _emptyUserOp(address sender, bytes memory signature) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    /// @notice **Feature: erc6900-modular-tba, Property 21: EntryPoint Caller Verification**
    /// @notice validateUserOp must revert when caller is not EntryPoint
    /// @notice **Validates: Requirements 2.3**
    function testProperty_EntryPointCallerVerification(address caller) public {
        address entryPoint = address(0x1234);
        vm.assume(caller != entryPoint);

        PositionMSCAEntryPointHarness account = new PositionMSCAEntryPointHarness(entryPoint);
        PackedUserOperation memory userOp = _emptyUserOp(address(account), "");

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PositionMSCA.InvalidEntryPoint.selector, caller));
        account.validateUserOp(userOp, bytes32(0), 0);
    }

    /// @notice **Feature: erc6900-modular-tba, Property 22: EntryPoint Payment**
    /// @notice validateUserOp must pay missingAccountFunds to EntryPoint
    /// @notice **Validates: Requirements 2.4**
    function testProperty_EntryPointPayment(uint256 missingAccountFunds, bytes32 userOpHash) public {
        missingAccountFunds = bound(missingAccountFunds, 0, 10 ether);

        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        address entryPoint = address(0x1234);

        MockPositionNFT nft = new MockPositionNFT();
        uint256 tokenId = nft.mint(owner);

        PositionMSCAEntryPointHarness account = new PositionMSCAEntryPointHarness(entryPoint);
        account.setTokenData(block.chainid, address(nft), tokenId);

        vm.deal(address(account), missingAccountFunds);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        PackedUserOperation memory userOp = _emptyUserOp(address(account), signature);

        uint256 balanceBefore = entryPoint.balance;
        vm.prank(entryPoint);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, missingAccountFunds);

        assertEq(validationData, 0, "validationData should be success");
        assertEq(entryPoint.balance, balanceBefore + missingAccountFunds, "EntryPoint should be paid");
    }
}

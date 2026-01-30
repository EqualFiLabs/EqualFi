// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC165} from "../interfaces/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccount, IAccountExecute, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IERC6551Account} from "../interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../interfaces/IERC6551Executable.sol";
import {IERC6900Account} from "./IERC6900Account.sol";
import {Call, ExecutionManifest, ModuleEntity} from "./ModuleTypes.sol";
import {MSCAStorage} from "./MSCAStorage.sol";
import {TokenDataLib} from "./TokenDataLib.sol";
import {ValidationConfig} from "./ModuleTypes.sol";
import {ValidationManagementLib} from "./ValidationManagementLib.sol";
import {ExecutionManagementLib} from "./ExecutionManagementLib.sol";
import {ValidationFlowLib} from "./ValidationFlowLib.sol";
import {ExecutionFlowLib} from "./ExecutionFlowLib.sol";

/// @title PositionMSCA
/// @notice Core ERC-6900 modular account implementation for Position NFT TBAs
abstract contract PositionMSCA is
    IERC6900Account,
    IAccount,
    IAccountExecute,
    IERC6551Account,
    IERC6551Executable,
    IERC1271,
    IERC165,
    IERC721Receiver
{
    bytes4 internal constant ERC6551_VALID_SIGNER = 0x523e3260;
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    address public immutable entryPoint;

    uint256 internal _state;
    bool internal _bootstrapActive;

    error UnauthorizedCaller(address caller);
    error InvalidEntryPoint(address caller);
    error EntryPointPaymentFailed(uint256 amount);
    error ModuleTargetNotAllowed(address target);
    error UnsupportedOperation(uint8 operation);
    error SelectorNotInstalled(bytes4 selector);
    error ModuleSelfModification(address module);

    constructor(address entryPoint_) {
        entryPoint = entryPoint_;
        _bootstrapActive = true;
    }

    receive() external payable {}

    fallback() external payable {
        bytes4 selector = msg.sig;
        MSCAStorage.ExecutionData storage execData = MSCAStorage.layout().executionData[selector];
        if (execData.module != address(0)) {
            if (msg.sender != address(this) && !execData.skipRuntimeValidation) {
                _requireOwner();
            }

            bytes memory result = _executeModuleWithHooks(msg.data);
            assembly {
                return(add(result, 0x20), mload(result))
            }
        }

        (bytes memory data, bytes memory authorization) = abi.decode(msg.data, (bytes, bytes));
        bytes memory output = _executeWithRuntimeValidation(data, authorization);
        assembly {
            return(add(output, 0x20), mload(output))
        }
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        virtual
        override
        returns (uint256 validationData)
    {
        if (msg.sender != entryPoint) {
            revert InvalidEntryPoint(msg.sender);
        }

        validationData = _validateUserOp(userOp, userOpHash);
        _payEntryPoint(missingAccountFunds);
    }

    function executeUserOp(PackedUserOperation calldata userOp, bytes32) external virtual override {
        if (msg.sender != entryPoint) {
            revert InvalidEntryPoint(msg.sender);
        }

        (bool ok, bytes memory result) = address(this).call(userOp.callData);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function executeWithRuntimeValidation(bytes calldata data, bytes calldata authorization)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        return _executeWithRuntimeValidation(data, authorization);
    }

    function installExecution(address module, ExecutionManifest calldata manifest, bytes calldata installData)
        external
        virtual
        override
    {
        _requireModuleManagement(module);

        ExecutionManagementLib.checkSelectorConflicts(manifest);
        ExecutionManagementLib.storeExecutionData(module, manifest);
        ExecutionManagementLib.storeExecutionHooks(module, manifest);
        ExecutionManagementLib.addInterfaceIds(manifest.interfaceIds);
        ExecutionManagementLib.markModuleInstalled(module);
        ExecutionManagementLib.callOnInstall(module, installData);
        _incrementState();

        emit ExecutionInstalled(module, manifest);
    }

    function uninstallExecution(address module, ExecutionManifest calldata manifest, bytes calldata uninstallData)
        external
        virtual
        override
    {
        _requireModuleManagement(module);

        ExecutionManagementLib.removeExecutionData(module, manifest);
        ExecutionManagementLib.removeExecutionHooks(module, manifest);
        ExecutionManagementLib.removeInterfaceIds(manifest.interfaceIds);
        ExecutionManagementLib.clearModuleInstalled(module);
        bool onUninstallSucceeded = ExecutionManagementLib.tryOnUninstall(module, uninstallData);
        _incrementState();

        emit ExecutionUninstalled(module, onUninstallSucceeded, manifest);
    }

    function installValidation(
        ValidationConfig validationConfig,
        bytes4[] calldata selectors,
        bytes calldata installData,
        bytes[] calldata hooks
    ) external virtual override {
        (ModuleEntity validationFunction, address module, uint32 entityId, uint8 flags) =
            ValidationManagementLib.decodeValidationConfig(validationConfig);
        _requireModuleManagement(module);
        ValidationManagementLib.storeValidationData(validationFunction, selectors, flags);
        ValidationManagementLib.storeValidationHooks(validationFunction, hooks);
        ValidationManagementLib.markModuleInstalled(module);
        ValidationManagementLib.callOnInstall(module, installData);
        _incrementState();
        emit ValidationInstalled(module, entityId);
    }

    function uninstallValidation(
        ModuleEntity validationFunction,
        bytes calldata uninstallData,
        bytes[] calldata hookUninstallData
    ) external virtual override {
        (address module, uint32 entityId) = ValidationManagementLib.decodeValidationFunction(validationFunction);
        _requireModuleManagement(module);
        uint256 hookDataIndex = ValidationManagementLib.uninstallValidationHooks(
            validationFunction,
            hookUninstallData,
            0
        );
        ValidationManagementLib.uninstallExecutionHooks(validationFunction, hookUninstallData, hookDataIndex);
        ValidationManagementLib.clearValidationState(validationFunction, module);
        bool onUninstallSucceeded = ValidationManagementLib.tryUninstallModule(module, uninstallData);
        _incrementState();
        emit ValidationUninstalled(module, entityId, onUninstallSucceeded);
    }

    function token() public view virtual override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        (, chainId, tokenContract, tokenId) = TokenDataLib.getTokenData();
    }

    function state() external view returns (uint256) {
        return _state;
    }

    function owner() external view override returns (address) {
        return _owner();
    }

    function nonce() external view override returns (uint256) {
        return _state;
    }

    function isValidSigner(address signer, bytes calldata) external view override returns (bytes4) {
        return signer == _owner() ? ERC6551_VALID_SIGNER : bytes4(0xffffffff);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view virtual override returns (bytes4) {
        if (_bootstrapActive && signature.length == 65) {
            return _bootstrapValidateSignature(hash, signature) ? ERC1271_MAGICVALUE : bytes4(0xffffffff);
        }

        if (signature.length < 96) {
            return bytes4(0xffffffff);
        }

        (ModuleEntity validationFunction, bytes memory moduleSig) = abi.decode(signature, (ModuleEntity, bytes));
        ValidationFlowLib.ensureSelectorAllowed(validationFunction, IERC1271.isValidSignature.selector);
        ValidationFlowLib.ensureSignatureValidation(validationFunction);
        return ValidationFlowLib.runSignatureValidation(
            validationFunction,
            address(this),
            msg.sender,
            hash,
            moduleSig
        );
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6900Account).interfaceId ||
            interfaceId == type(IAccount).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC6551Executable).interfaceId ||
            interfaceId == type(IERC1271).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId
        ) {
            return true;
        }

        return MSCAStorage.layout().supportedInterfaces[interfaceId] != 0;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        _requireOwner();
        bytes memory result = _call(target, value, data);
        _incrementState();
        return result;
    }

    function executeBatch(Call[] calldata calls) external payable virtual override returns (bytes[] memory) {
        _requireOwner();
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        bytes[] memory results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            if (ds.installedModules[calls[i].target]) {
                revert ModuleTargetNotAllowed(calls[i].target);
            }
            results[i] = _call(calls[i].target, calls[i].value, calls[i].data);
        }

        _incrementState();
        return results;
    }

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        _requireOwner();

        if (operation == 0) {
            bytes memory result = _call(to, value, data);
            _incrementState();
            return result;
        }

        if (operation == 1) {
            if (value != 0) {
                revert UnsupportedOperation(operation);
            }
            bytes memory result = _delegateCall(to, data);
            _incrementState();
            return result;
        }

        revert UnsupportedOperation(operation);
    }

    function _owner() internal view virtual returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid || tokenContract == address(0)) {
            return address(0);
        }
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function _requireOwner() internal view {
        if (msg.sender != _owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
    }

    function _requireModuleManagement(address module) internal view {
        _requireOwner();
        if (msg.sender == module) {
            revert ModuleSelfModification(module);
        }
    }

    function _incrementState() internal {
        unchecked {
            _state++;
        }
    }

    function _bootstrapValidateUserOp(bytes32 userOpHash, bytes calldata signature) internal view returns (uint256) {
        if (!_bootstrapActive) {
            return SIG_VALIDATION_FAILED;
        }

        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(userOpHash, signature);
        if (error != ECDSA.RecoverError.NoError || signer != _owner()) {
            return SIG_VALIDATION_FAILED;
        }

        return 0;
    }

    function _validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) internal returns (uint256) {
        if (_bootstrapActive && userOp.signature.length == 65) {
            return _bootstrapValidateUserOp(userOpHash, userOp.signature);
        }

        (ModuleEntity validationFunction, bytes memory moduleSig) =
            abi.decode(userOp.signature, (ModuleEntity, bytes));

        bytes4 selector = _selectorFromCalldata(userOp.callData);
        ValidationFlowLib.ensureSelectorAllowed(validationFunction, selector);
        ValidationFlowLib.ensureUserOpValidation(validationFunction);

        PackedUserOperation memory userOpCopy = userOp;
        userOpCopy.signature = moduleSig;

        return ValidationFlowLib.runUserOpValidation(validationFunction, userOpCopy, userOpHash);
    }

    function _selectorFromCalldata(bytes calldata data) internal pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := calldataload(data.offset)
        }
    }

    function _selectorFromMemory(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _executeWithRuntimeValidation(bytes memory data, bytes memory authorization)
        internal
        returns (bytes memory)
    {
        (ModuleEntity validationFunction, bytes memory moduleAuth) = abi.decode(authorization, (ModuleEntity, bytes));
        bytes4 selector = _selectorFromMemory(data);
        ValidationFlowLib.ensureSelectorAllowed(validationFunction, selector);
        ValidationFlowLib.runRuntimeValidation(
            validationFunction,
            address(this),
            msg.sender,
            msg.value,
            data,
            moduleAuth
        );

        (bool ok, bytes memory result) = address(this).call(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        _incrementState();
        return result;
    }

    function _executeModuleWithHooks(bytes calldata data) internal returns (bytes memory) {
        bytes4 selector = _selectorFromCalldata(data);
        MSCAStorage.ExecutionData storage execData = MSCAStorage.layout().executionData[selector];
        address module = execData.module;
        if (module == address(0)) {
            revert SelectorNotInstalled(selector);
        }

        ExecutionFlowLib.enterHookContext();
        (bytes[] memory preHookData, uint256 gasUsed) =
            ExecutionFlowLib.runPreHooks(selector, msg.sender, msg.value, data);
        bytes memory result = _delegateCall(module, data);
        _incrementState();
        ExecutionFlowLib.runPostHooks(selector, preHookData, gasUsed);
        ExecutionFlowLib.exitHookContext();
        return result;
    }


    function _bootstrapValidateSignature(bytes32 hash, bytes calldata signature) internal view returns (bool) {
        if (!_bootstrapActive) {
            return false;
        }

        (address signer, ECDSA.RecoverError error, ) = ECDSA.tryRecoverCalldata(hash, signature);
        return error == ECDSA.RecoverError.NoError && signer == _owner();
    }

    function _payEntryPoint(uint256 missingAccountFunds) internal {
        if (missingAccountFunds == 0) {
            return;
        }

        (bool success, ) = payable(entryPoint).call{value: missingAccountFunds}("");
        if (!success) {
            revert EntryPointPaymentFailed(missingAccountFunds);
        }
    }

    function _call(address target, uint256 value, bytes calldata data) internal returns (bytes memory) {
        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    function _delegateCall(address target, bytes calldata data) internal returns (bytes memory) {
        (bool ok, bytes memory result) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}

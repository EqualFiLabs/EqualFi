// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../libraries/LibModuleRegistry.sol";
import {IModuleRegistryFacet} from "../interfaces/IModuleRegistryFacet.sol";
import {
    ModuleNotFound,
    ModuleInactive,
    ModuleRegistrationDisabled,
    ModuleIncorrectFee,
    NotModuleOwner,
    InvalidModuleOwner,
    ModuleAumOutOfBounds,
    TreasuryNotSet,
    PoolCreationFeeTransferFailed,
    InvalidAumFeeBounds
} from "../libraries/Errors.sol";

/// @notice Registration/admin controls for module encumbrance.
contract ModuleRegistryFacet is IModuleRegistryFacet {
    function registerModule(bytes32 metadataHash) external payable returns (uint256 moduleId) {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        bool governanceCaller = LibAccess.isOwnerOrTimelock(msg.sender);
        uint256 fee = ms.moduleCreationFee;

        if (governanceCaller) {
            if (msg.value != 0) {
                revert ModuleIncorrectFee(msg.value, 0);
            }
        } else {
            if (fee == 0) {
                revert ModuleRegistrationDisabled();
            }
            if (msg.value != fee) {
                revert ModuleIncorrectFee(msg.value, fee);
            }

            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury == address(0)) {
                revert TreasuryNotSet();
            }
            (bool ok,) = payable(treasury).call{value: msg.value}("");
            if (!ok) {
                revert PoolCreationFeeTransferFailed();
            }
        }

        moduleId = _nextModuleId(ms);
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = msg.sender;
        m.metadataHash = metadataHash;
        m.paused = false;
        m.inactive = false;
        m.aumBps = ms.defaultModuleAumBps;

        LibModuleRegistry.emitModuleRegistered(moduleId, msg.sender, metadataHash, m.aumBps);
    }

    function setModuleOwner(uint256 moduleId, address newOwner) external {
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        _enforceModuleOwner(moduleId, m.owner);
        if (newOwner == address(0)) {
            revert InvalidModuleOwner(newOwner);
        }
        address oldOwner = m.owner;
        m.owner = newOwner;
        LibModuleRegistry.emitModuleOwnerUpdated(moduleId, oldOwner, newOwner);
    }

    function pauseModule(uint256 moduleId) external {
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        _enforceModuleOwnerOrGovernance(moduleId, m.owner);
        m.paused = true;
        LibModuleRegistry.emitModulePauseUpdated(moduleId, true);
    }

    function unpauseModule(uint256 moduleId) external {
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        _enforceModuleOwnerOrGovernance(moduleId, m.owner);
        if (m.inactive) {
            revert ModuleInactive(moduleId);
        }
        m.paused = false;
        LibModuleRegistry.emitModulePauseUpdated(moduleId, false);
    }

    function setModuleCreationFee(uint256 fee) external {
        LibAccess.enforceOwnerOrTimelock();
        LibModuleRegistry.s().moduleCreationFee = fee;
    }

    function setDefaultModuleAumBps(uint16 bps) external {
        LibAccess.enforceOwnerOrTimelock();
        _enforceAumBpsInBounds(bps);
        LibModuleRegistry.s().defaultModuleAumBps = bps;
    }

    function setModuleAumBps(uint256 moduleId, uint16 bps) external {
        LibAccess.enforceOwnerOrTimelock();
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        _enforceAumBpsInBounds(bps);
        m.aumBps = bps;
    }

    function setModuleAumBounds(uint16 minBps, uint16 maxBps) external {
        LibAccess.enforceOwnerOrTimelock();
        if (minBps > maxBps) {
            revert InvalidAumFeeBounds();
        }
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        ms.minModuleAumBps = minBps;
        ms.maxModuleAumBps = maxBps;
    }

    function setModuleDeactivationGraceEpochs(uint16 epochs) external {
        LibAccess.enforceOwnerOrTimelock();
        LibModuleRegistry.s().deactivationGraceEpochs = epochs;
    }

    function setModuleAciPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibModuleRegistry.s().moduleAciPaused = paused;
        LibModuleRegistry.emitModuleAciPauseToggled(paused);
    }

    function _nextModuleId(LibModuleRegistry.ModuleStorage storage ms) internal returns (uint256 moduleId) {
        uint256 next = ms.nextModuleId;
        if (next == 0) {
            next = 1;
        }
        moduleId = next;
        ms.nextModuleId = next + 1;
    }

    function _requireModule(uint256 moduleId) internal view returns (LibModuleRegistry.Module storage m) {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        uint256 next = ms.nextModuleId;
        if (moduleId == 0 || next == 0 || moduleId >= next) {
            revert ModuleNotFound(moduleId);
        }
        m = ms.modules[moduleId];
    }

    function _enforceModuleOwner(uint256 moduleId, address owner) internal view {
        if (msg.sender != owner) {
            revert NotModuleOwner(moduleId, msg.sender);
        }
    }

    function _enforceModuleOwnerOrGovernance(uint256 moduleId, address owner) internal view {
        if (msg.sender == owner || LibAccess.isOwnerOrTimelock(msg.sender)) {
            return;
        }
        revert NotModuleOwner(moduleId, msg.sender);
    }

    function _enforceAumBpsInBounds(uint16 bps) internal view {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (bps < ms.minModuleAumBps || bps > ms.maxModuleAumBps) {
            revert ModuleAumOutOfBounds(bps, ms.minModuleAumBps, ms.maxModuleAumBps);
        }
    }
}

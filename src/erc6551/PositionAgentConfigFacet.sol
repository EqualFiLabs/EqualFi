// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {PositionAgent_NotAdmin} from "../libraries/PositionAgentErrors.sol";

/// @title PositionAgentConfigFacet
/// @notice Admin configuration for ERC-6551 Position Agent integration
contract PositionAgentConfigFacet {
    event ERC6551RegistryUpdated(address indexed previous, address indexed current);
    event ERC6551ImplementationUpdated(address indexed previous, address indexed current);
    event IdentityRegistryUpdated(address indexed previous, address indexed current);

    function setERC6551Registry(address newRegistry) external {
        _requireAdmin();
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address previous = ds.erc6551Registry;
        ds.erc6551Registry = newRegistry;
        emit ERC6551RegistryUpdated(previous, newRegistry);
    }

    function setERC6551Implementation(address newImplementation) external {
        _requireAdmin();
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address previous = ds.erc6551Implementation;
        ds.erc6551Implementation = newImplementation;
        emit ERC6551ImplementationUpdated(previous, newImplementation);
    }

    function setIdentityRegistry(address newRegistry) external {
        _requireAdmin();
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address previous = ds.identityRegistry;
        ds.identityRegistry = newRegistry;
        emit IdentityRegistryUpdated(previous, newRegistry);
    }

    function _requireAdmin() internal view {
        if (!LibAccess.isOwnerOrTimelock(msg.sender)) {
            revert PositionAgent_NotAdmin(msg.sender);
        }
    }
}

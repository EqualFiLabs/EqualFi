// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

contract IdentityRegistry {
    address public registry;

    event RegistryUpdated(address indexed previous, address indexed current);

    constructor(address _registry) {
        registry = _registry;
    }

    function setRegistry(address _registry) external {
        address previous = registry;
        registry = _registry;
        emit RegistryUpdated(previous, _registry);
    }
}

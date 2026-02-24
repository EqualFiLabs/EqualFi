// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

contract IdentityRegistry {
    address public registry;
    mapping(address => bool) public registered;

    event RegistryUpdated(address indexed previous, address indexed current);
    event Registered(address indexed account);

    constructor(address _registry) {
        registry = _registry;
    }

    function setRegistry(address _registry) external {
        address previous = registry;
        registry = _registry;
        emit RegistryUpdated(previous, _registry);
    }

    function register() external {
        registered[msg.sender] = true;
        emit Registered(msg.sender);
    }

    function isRegistered(address account) external view returns (bool) {
        return registered[account];
    }
}

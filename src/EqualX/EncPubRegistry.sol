// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IEncPubRegistry} from "../interfaces/IEncPubRegistry.sol";

/// @notice Minimal registry mapping participant addresses to compressed secp256k1 encryption pubkeys.
contract EncPubRegistry is IEncPubRegistry {
    error InvalidPubkey();

    mapping(address => bytes) private pubkeys;

    /// @inheritdoc IEncPubRegistry
    function registerEncPub(bytes calldata encPub) external override {
        if (encPub.length != 33) revert InvalidPubkey();
        pubkeys[msg.sender] = encPub;
        emit KeyRegistered(msg.sender, encPub);
    }

    /// @inheritdoc IEncPubRegistry
    function getEncPub(address owner) external view override returns (bytes memory) {
        return pubkeys[owner];
    }

    /// @inheritdoc IEncPubRegistry
    function isRegistered(address owner) external view override returns (bool) {
        return pubkeys[owner].length != 0;
    }
}

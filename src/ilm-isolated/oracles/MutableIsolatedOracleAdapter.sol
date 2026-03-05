// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IIlmIsolatedOracleAdapter} from "../interfaces/IIlmIsolatedOracleAdapter.sol";

/// @notice Owner-controlled mutable oracle adapter for ILM isolated testing.
/// @dev Designed for local/dev usage (Anvil). Supports manual price and timestamp updates.
contract MutableIsolatedOracleAdapter is IIlmIsolatedOracleAdapter {
    error NotOwner();
    error ZeroAddress();

    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    address public owner;
    mapping(address => PriceData) internal prices;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PriceUpdated(address indexed oracle, uint256 price, uint256 updatedAt);

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _setPrice(address(this), initialPrice, block.timestamp);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    /// @notice Transfer adapter ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Set adapter price for the default key (`address(this)`) with current timestamp.
    function setPrice(uint256 price) external onlyOwner {
        _setPrice(address(this), price, block.timestamp);
    }

    /// @notice Set adapter price for the default key (`address(this)`) with explicit timestamp.
    function setPriceWithTimestamp(uint256 price, uint256 updatedAt) external onlyOwner {
        _setPrice(address(this), price, updatedAt);
    }

    /// @notice Set adapter price for an explicit oracle key with current timestamp.
    function setPriceFor(address oracle, uint256 price) external onlyOwner {
        _setPrice(oracle, price, block.timestamp);
    }

    /// @notice Set adapter price for an explicit oracle key with explicit timestamp.
    function setPriceForWithTimestamp(address oracle, uint256 price, uint256 updatedAt) external onlyOwner {
        _setPrice(oracle, price, updatedAt);
    }

    /// @inheritdoc IIlmIsolatedOracleAdapter
    function getIsolatedPrice(address oracle) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[oracle];
        if (data.updatedAt == 0 && oracle != address(this)) {
            data = prices[address(this)];
        }
        return (data.price, data.updatedAt);
    }

    /// @notice Returns raw stored data for a specific oracle key.
    function getPriceData(address oracle) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[oracle];
        return (data.price, data.updatedAt);
    }

    function _setPrice(address oracle, uint256 price, uint256 updatedAt) internal {
        if (oracle == address(0)) {
            revert ZeroAddress();
        }
        prices[oracle] = PriceData({price: price, updatedAt: updatedAt});
        emit PriceUpdated(oracle, price, updatedAt);
    }
}

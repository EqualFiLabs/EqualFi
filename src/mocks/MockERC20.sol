// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple ERC20 mock with external minting for tests and simulations.
contract MockERC20 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 _amount) ERC20(name_, symbol_) {
        _decimals = decimals_;
        _mint(msg.sender, _amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

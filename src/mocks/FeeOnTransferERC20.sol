// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/// @notice Mock ERC20 with a configurable fee-on-transfer (basis points) sent to a sink address.
contract FeeOnTransferERC20 is MockERC20 {
    uint16 public feeBps;
    address public feeSink;

    constructor(string memory name, string memory symbol, uint8 decimals_, uint256 supply, uint16 _feeBps, address _feeSink)
        MockERC20(name, symbol, decimals_, supply)
    {
        feeBps = _feeBps;
        feeSink = _feeSink;
    }

    function _chargeFee(address from, uint256 amount) internal returns (uint256 net) {
        if (feeBps == 0 || feeSink == address(0)) {
            return amount;
        }
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) {
            _transfer(from, feeSink, fee);
        }
        net = amount - fee;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 net = _chargeFee(msg.sender, amount);
        return super.transfer(to, net);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // spend allowance on full amount to mimic typical fee-on-transfer behavior
        _spendAllowance(from, msg.sender, amount);
        uint256 net = _chargeFee(from, amount);
        _transfer(from, to, net);
        return true;
    }
}

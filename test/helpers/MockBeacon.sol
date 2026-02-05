// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

contract MockBeacon is IBeacon {
    address public implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    function setImplementation(address newImplementation) external {
        implementation = newImplementation;
    }
}

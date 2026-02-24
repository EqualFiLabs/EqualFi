// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IdentityRegistry} from "../test/IdentityRegistry.sol";

contract DeployIdentityScript is Script {
    function run() external {
        vm.startBroadcast();
        new IdentityRegistry(address(0));
        vm.stopBroadcast();
    }
}

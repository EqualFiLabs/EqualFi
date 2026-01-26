// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Faucet} from "../src/faucet/Faucet.sol";

/// @notice Deploy the faucet with an explicit owner.
contract DeployFaucetScript is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        Faucet faucet = new Faucet(owner);
        vm.stopBroadcast();

        console2.log("Faucet", address(faucet));
    }
}

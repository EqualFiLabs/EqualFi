// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployDiamondRobinhoodScript} from "../../script/DeployDiamondRobinhood.s.sol";

contract DeployDiamondRobinhoodScriptTest is Test {
    DeployDiamondRobinhoodScript internal deployScript;

    function setUp() public {
        deployScript = new DeployDiamondRobinhoodScript();
    }

    function testDefaultIdentityRegistryForRobinhood() public {
        address registry = deployScript.defaultIdentityRegistryForChain(46630);
        assertEq(registry, 0x47869902e1a9B009eE520E88e7DD73c87c840Fa6);
    }

    function testDefaultIdentityRegistryForKnownChains() public {
        assertEq(
            deployScript.defaultIdentityRegistryForChain(1),
            0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
        );
        assertEq(
            deployScript.defaultIdentityRegistryForChain(11155111),
            0x8004A818BFB912233c491871b3d84c89A494BD9e
        );
    }

    function testDefaultIdentityRegistryUnknownChainReturnsZero() public {
        assertEq(deployScript.defaultIdentityRegistryForChain(31337), address(0));
    }
}

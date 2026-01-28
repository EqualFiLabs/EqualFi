// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004TestBase} from "./ERC8004TestBase.sol";

contract ERC8004URIRoundTripPropertyTest is ERC8004TestBase {
    // Feature: erc8004-position-nft, Property 2: URI Round-Trip Consistency
    // Validates: Requirements 2.1, 2.4, 2.5
    function testFuzz_uriRoundTripConsistency(string memory agentURI) public {
        address user = address(0xBEEF);
        vm.startPrank(user);
        uint256 agentId = identity.register();
        identity.setAgentURI(agentId, agentURI);
        assertEq(identity.getAgentURI(agentId), agentURI);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004TestBase} from "./ERC8004TestBase.sol";

contract ERC8004MetadataRoundTripPropertyTest is ERC8004TestBase {
    // Feature: erc8004-position-nft, Property 3: Metadata Round-Trip Consistency
    // Validates: Requirements 3.1, 3.5
    function testFuzz_metadataRoundTripConsistency(string memory key, bytes memory value) public {
        vm.assume(!_isReservedKey(key));
        address user = address(0xBEEF);
        vm.startPrank(user);
        uint256 agentId = identity.register();
        identity.setMetadata(agentId, key, value);
        assertEq(identity.getMetadata(agentId, key), value);
        vm.stopPrank();
    }
}

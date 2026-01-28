// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {PositionNFTIdentityFacet} from "../../src/erc8004/PositionNFTIdentityFacet.sol";
import {ERC8004TestBase} from "./ERC8004TestBase.sol";

contract ERC8004RegistrationPropertyTest is ERC8004TestBase {
    // Feature: erc8004-position-nft, Property 1: Registration Data Integrity
    // Validates: Requirements 1.1, 1.2, 1.3, 1.4, 8.1, 8.3
    function testFuzz_registrationDataIntegrity(bytes32 seed, uint8 rawLen) public {
        uint256 len = bound(uint256(rawLen), 0, 4);
        string memory agentURI = string(abi.encodePacked("uri:", seed));

        PositionNFTIdentityFacet.MetadataEntry[] memory metadata =
            new PositionNFTIdentityFacet.MetadataEntry[](len);
        for (uint256 i = 0; i < len; i++) {
            string memory key = string(abi.encodePacked("key:", seed, ":", bytes32(uint256(i))));
            if (_isReservedKey(key)) {
                key = string(abi.encodePacked(key, ":alt"));
            }
            metadata[i] = PositionNFTIdentityFacet.MetadataEntry({
                metadataKey: key,
                metadataValue: abi.encodePacked(seed, i)
            });
        }

        address user = address(0xBEEF);
        vm.startPrank(user);
        vm.recordLogs();
        uint256 agentId = identity.register(agentURI, metadata);
        vm.stopPrank();

        assertEq(agentId, 1);
        assertEq(identity.getAgentURI(agentId), agentURI);
        for (uint256 i = 0; i < len; i++) {
            assertEq(identity.getMetadata(agentId, metadata[i].metadataKey), metadata[i].metadataValue);
        }

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 registeredSig = keccak256("Registered(uint256,string,address)");
        bytes32 metadataSig = keccak256("MetadataSet(uint256,string,string,bytes)");
        uint256 registeredCount;
        uint256 metadataCount;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) {
                continue;
            }
            if (entries[i].topics[0] == registeredSig) {
                registeredCount++;
            } else if (entries[i].topics[0] == metadataSig) {
                metadataCount++;
            }
        }

        assertEq(registeredCount, 1);
        assertEq(metadataCount, len);
    }
}

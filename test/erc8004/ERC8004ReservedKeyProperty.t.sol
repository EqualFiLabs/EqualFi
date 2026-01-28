// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004TestBase} from "./ERC8004TestBase.sol";
import {PositionNFTIdentityFacet} from "../../src/erc8004/PositionNFTIdentityFacet.sol";
import {ERC8004_ReservedMetadataKey} from "../../src/libraries/ERC8004Errors.sol";

contract ERC8004ReservedKeyPropertyTest is ERC8004TestBase {
    // Feature: erc8004-position-nft, Property 5: Reserved Key Protection
    // Validates: Requirements 1.5, 3.4
    function test_reservedKeyProtection() public {
        address owner = address(0xBEEF);
        vm.startPrank(owner);

        PositionNFTIdentityFacet.MetadataEntry[] memory metadata = new PositionNFTIdentityFacet.MetadataEntry[](1);
        metadata[0] = PositionNFTIdentityFacet.MetadataEntry({
            metadataKey: "agentWallet",
            metadataValue: abi.encode(address(0x1234))
        });

        vm.expectRevert(abi.encodeWithSelector(ERC8004_ReservedMetadataKey.selector, "agentWallet"));
        identity.register("ipfs://agent", metadata);

        uint256 agentId = identity.register();
        vm.expectRevert(abi.encodeWithSelector(ERC8004_ReservedMetadataKey.selector, "agentWallet"));
        identity.setMetadata(agentId, "agentWallet", abi.encode(address(0x1234)));

        vm.stopPrank();
    }
}

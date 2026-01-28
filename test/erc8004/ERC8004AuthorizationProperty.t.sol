// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004WalletTestBase} from "./ERC8004WalletTestBase.sol";
import {ERC8004_Unauthorized} from "../../src/libraries/ERC8004Errors.sol";

contract ERC8004AuthorizationPropertyTest is ERC8004WalletTestBase {
    // Feature: erc8004-position-nft, Property 4: Authorization Enforcement
    // Validates: Requirements 2.2, 2.3, 3.2, 3.3, 4.7, 10.1, 10.2, 10.3
    function test_authorizationEnforcement(bytes32 seed) public {
        address owner = address(0xBEEF);
        address operator = address(0xCAFE);
        address attacker = address(0xD00D);

        uint256 pk = uint256(seed);
        if (pk == 0) {
            pk = 1;
        } else {
            pk = uint256(bound(pk, 1, SECP256K1_ORDER - 1));
        }
        address newWallet = vm.addr(pk);

        vm.startPrank(owner);
        uint256 agentId = identity.register();
        vm.stopPrank();

        // Unauthorized caller should fail.
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ERC8004_Unauthorized.selector, attacker, agentId));
        identity.setAgentURI(agentId, "ipfs://bad");

        vm.expectRevert(abi.encodeWithSelector(ERC8004_Unauthorized.selector, attacker, agentId));
        identity.setMetadata(agentId, "note", bytes("x"));

        bytes memory sig = _sign(agentId, newWallet, 0, block.timestamp + 1 hours, pk);
        vm.expectRevert(abi.encodeWithSelector(ERC8004_Unauthorized.selector, attacker, agentId));
        wallet.setAgentWallet(agentId, newWallet, block.timestamp + 1 hours, sig);
        vm.stopPrank();

        // Approved operator should succeed.
        vm.startPrank(owner);
        nft.approve(operator, agentId);
        vm.stopPrank();

        vm.startPrank(operator);
        identity.setAgentURI(agentId, "ipfs://ok");
        identity.setMetadata(agentId, "note", bytes("ok"));
        wallet.setAgentWallet(agentId, newWallet, block.timestamp + 1 hours, sig);
        vm.stopPrank();
    }

    function _sign(uint256 agentId, address newWallet, uint256 nonce, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(wallet.SET_AGENT_WALLET_TYPEHASH(), agentId, newWallet, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", wallet.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

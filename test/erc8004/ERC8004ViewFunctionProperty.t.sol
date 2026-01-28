// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004ViewTestBase} from "./ERC8004ViewTestBase.sol";

contract ERC8004ViewFunctionPropertyTest is ERC8004ViewTestBase {
    // Feature: erc8004-position-nft, Property 10: View Function Consistency
    // Validates: Requirements 7.1, 7.2
    function test_viewFunctionConsistency(bytes32 seed) public {
        address owner = address(0xBEEF);
        uint256 pk = uint256(seed);
        if (pk == 0) {
            pk = 1;
        } else {
            pk = uint256(bound(pk, 1, SECP256K1_ORDER - 1));
        }
        address newWallet = vm.addr(pk);

        vm.startPrank(owner);
        uint256 agentId = identity.register();

        // Before setAgentWallet: expect zero wallet and zero nonce.
        assertEq(viewFacet.getAgentWallet(agentId), address(0));
        assertEq(viewFacet.getAgentNonce(agentId), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(agentId, newWallet, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        wallet.setAgentWallet(agentId, newWallet, deadline, sig);
        vm.stopPrank();

        assertEq(viewFacet.getAgentWallet(agentId), newWallet);
        assertEq(viewFacet.getAgentNonce(agentId), 1);
    }


    function _digest(uint256 agentId, address newWallet, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(wallet.SET_AGENT_WALLET_TYPEHASH(), agentId, newWallet, nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", wallet.DOMAIN_SEPARATOR(), structHash));
    }
}

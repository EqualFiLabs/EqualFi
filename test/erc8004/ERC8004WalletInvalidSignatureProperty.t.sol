// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004WalletTestBase} from "./ERC8004WalletTestBase.sol";
import {
    ERC8004_InvalidSignature,
    ERC8004_InvalidSignatureLength,
    ERC8004_DeadlineExpired
} from "../../src/libraries/ERC8004Errors.sol";

contract ERC8004WalletInvalidSignaturePropertyTest is ERC8004WalletTestBase {
    // Feature: erc8004-position-nft, Property 7: Invalid Signature Rejection
    // Validates: Requirements 4.4, 4.5
    function test_invalidSignatureRejected(bytes32 seed) public {
        address owner = address(0xBEEF);
        uint256 pk = uint256(seed);
        if (pk == 0) {
            pk = 1;
        } else {
            pk = uint256(bound(pk, 1, SECP256K1_ORDER - 2));
        }
        address newWallet = vm.addr(pk);

        vm.startPrank(owner);
        uint256 agentId = identity.register();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(agentId, newWallet, 0, deadline);

        // Sign with a different key to make signature invalid.
        uint256 wrongPk = pk + 1;
        address wrongWallet = vm.addr(wrongPk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(ERC8004_InvalidSignature.selector));
        wallet.setAgentWallet(agentId, newWallet, deadline, sig);

        // Invalid signature length.
        vm.expectRevert(abi.encodeWithSelector(ERC8004_InvalidSignatureLength.selector, 10));
        wallet.setAgentWallet(agentId, newWallet, deadline, bytes("1234567890"));

        // Expired deadline.
        bytes32 digestExpired = _digest(agentId, wrongWallet, 0, block.timestamp - 1);
        (v, r, s) = vm.sign(wrongPk, digestExpired);
        bytes memory sigExpired = abi.encodePacked(r, s, v);
        vm.expectRevert(
            abi.encodeWithSelector(ERC8004_DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        wallet.setAgentWallet(agentId, wrongWallet, block.timestamp - 1, sigExpired);

        vm.stopPrank();
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

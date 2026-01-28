// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC8004WalletTestBase} from "./ERC8004WalletTestBase.sol";
import {
    ERC8004_NonceAlreadyUsed
} from "../../src/libraries/ERC8004Errors.sol";

contract ERC8004WalletValidSignaturePropertyTest is ERC8004WalletTestBase {
    bytes4 private constant ERC1271_MAGICVALUE = 0x1626ba7e;

    // Feature: erc8004-position-nft, Property 6: Valid Signature Acceptance
    // Validates: Requirements 4.1, 4.2, 4.6, 6.4, 6.5
    function test_validEOASignatureAcceptance(bytes32 seed) public {
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

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(agentId, newWallet, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        wallet.setAgentWallet(agentId, newWallet, deadline, sig);
        vm.stopPrank();

        bytes memory stored = identity.getMetadata(agentId, "agentWallet");
        address storedWallet = abi.decode(stored, (address));
        assertEq(storedWallet, newWallet);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC8004_NonceAlreadyUsed.selector, agentId, 0));
        wallet.setAgentWallet(agentId, newWallet, deadline, sig);
        vm.stopPrank();
    }

    function test_validERC1271SignatureAcceptance() public {
        address owner = address(0xBEEF);
        MockERC1271Wallet contractWallet = new MockERC1271Wallet();

        vm.startPrank(owner);
        uint256 agentId = identity.register();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _digest(agentId, address(contractWallet), 0, deadline);
        bytes memory sig = hex"123456";
        contractWallet.setExpected(digest, sig);

        wallet.setAgentWallet(agentId, address(contractWallet), deadline, sig);
        vm.stopPrank();

        bytes memory stored = identity.getMetadata(agentId, "agentWallet");
        address storedWallet = abi.decode(stored, (address));
        assertEq(storedWallet, address(contractWallet));
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

contract MockERC1271Wallet {
    bytes4 private constant MAGICVALUE = 0x1626ba7e;
    bytes32 public expectedHash;
    bytes32 public expectedSigHash;

    function setExpected(bytes32 hash, bytes calldata sig) external {
        expectedHash = hash;
        expectedSigHash = keccak256(sig);
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (hash == expectedHash && keccak256(sig) == expectedSigHash) {
            return MAGICVALUE;
        }
        return 0xffffffff;
    }
}

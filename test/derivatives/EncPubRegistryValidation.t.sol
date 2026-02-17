// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EncPubRegistry} from "../../src/EqualX/EncPubRegistry.sol";
import {Mailbox} from "../../src/EqualX/Mailbox.sol";

contract EncPubRegistryValidationTest is Test {
    EncPubRegistry internal registry;
    Mailbox internal mailbox;

    bytes internal constant VALID_GENERATOR_COMPRESSED =
        hex"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    bytes internal constant INVALID_NON_CURVE_X5 =
        hex"020000000000000000000000000000000000000000000000000000000000000005";
    bytes internal constant INVALID_PREFIX =
        hex"040000000000000000000000000000000000000000000000000000000000000001";
    bytes internal constant INVALID_LENGTH = hex"02";

    function setUp() public {
        registry = new EncPubRegistry();
        mailbox = new Mailbox(address(this));
    }

    function test_registerEncPub_revertsForNonCurvePoint() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPubkey()"));
        registry.registerEncPub(INVALID_NON_CURVE_X5);
    }

    function test_registerEncPub_revertsForBadPrefixOrLength() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPubkey()"));
        registry.registerEncPub(INVALID_PREFIX);

        vm.expectRevert(abi.encodeWithSignature("InvalidPubkey()"));
        registry.registerEncPub(INVALID_LENGTH);
    }

    function test_registerEncPub_acceptsValidCompressedPoint() public {
        registry.registerEncPub(VALID_GENERATOR_COMPRESSED);
        assertTrue(registry.isRegistered(address(this)));
        assertEq(registry.getEncPub(address(this)), VALID_GENERATOR_COMPRESSED);
    }

    function test_mailboxUsesSharedPubkeyValidation() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPubkey()"));
        mailbox.registerPubkey(INVALID_NON_CURVE_X5);

        mailbox.registerPubkey(VALID_GENERATOR_COMPRESSED);
        assertEq(mailbox.deskEncryptionPubkey(address(this)), VALID_GENERATOR_COMPRESSED);
    }
}

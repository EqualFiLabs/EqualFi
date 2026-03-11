// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgenticFinancingFacet} from "../../src/synthesis/AgenticFinancingFacet.sol";
import {AgentMailboxFacet} from "../../src/synthesis/AgentMailboxFacet.sol";
import {LibAgenticFinancingStorage} from "../../src/libraries/LibAgenticFinancingStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";

contract AgenticFinancingHarness is AgenticFinancingFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }
}

contract AgentMailboxHarness is AgentMailboxFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function seedAgreement(uint256 agreementId, address borrower, address provider) external {
        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        a.id = agreementId;
        a.borrower = borrower;
        a.provider = provider;
        a.status = LibAgenticFinancingStorage.AgreementStatus.Active;
    }
}

contract AgenticFinancingPhase1Test is Test {
    AgenticFinancingHarness internal financing;
    AgentMailboxHarness internal mailbox;

    address internal borrower = address(0xB0B0);
    address internal provider = address(0xC0FEE);

    bytes32 internal constant POSITION_KEY = keccak256("POSITION_KEY");

    function setUp() public {
        financing = new AgenticFinancingHarness();
        financing.setOwner(address(this));

        mailbox = new AgentMailboxHarness();
        mailbox.setOwner(address(this));
    }

    function test_proposeAndActivate_setsNativeEncumbranceState() public {
        uint256 proposalId = financing.proposeAgreement(7, POSITION_KEY, borrower, provider, 1, 1_000e6, 100, bytes32(0));

        LibAgenticFinancingStorage.Proposal memory p = financing.getProposal(proposalId);
        assertEq(p.id, proposalId);
        assertEq(p.agentId, 7);
        assertEq(p.positionKey, POSITION_KEY);
        assertEq(p.borrower, borrower);
        assertEq(p.provider, provider);
        assertEq(p.principalRequested, 1_000e6);

        uint256 agreementId = financing.approveAndActivate(proposalId, 1);
        LibAgenticFinancingStorage.Agreement memory a = financing.getAgreement(agreementId);

        assertEq(a.id, agreementId);
        assertEq(a.proposalId, proposalId);
        assertEq(uint8(a.status), uint8(LibAgenticFinancingStorage.AgreementStatus.Active));
        assertEq(a.principalEncumbered, 1_000e6);
        assertEq(a.unitsEncumbered, 100);

        uint256[] memory keys = financing.getAgreementsByPositionKey(POSITION_KEY);
        assertEq(keys.length, 1);
        assertEq(keys[0], agreementId);
    }

    function test_applyUsage_andRepay_flow() public {
        uint256 proposalId = financing.proposeAgreement(8, POSITION_KEY, borrower, provider, 2, 500, 2, bytes32("meta"));
        uint256 agreementId = financing.approveAndActivate(proposalId, 2);

        vm.prank(provider);
        financing.applyUsage(agreementId, 25, 3, keccak256("USAGE_BATCH_1"));

        LibAgenticFinancingStorage.Agreement memory afterUsage = financing.getAgreement(agreementId);
        assertEq(afterUsage.principalEncumbered, 525);
        assertEq(afterUsage.unitsEncumbered, 5);

        vm.prank(borrower);
        financing.repay(agreementId, type(uint256).max);

        LibAgenticFinancingStorage.Agreement memory afterRepay = financing.getAgreement(agreementId);
        assertEq(afterRepay.principalEncumbered, 0);
        assertEq(uint8(afterRepay.status), uint8(LibAgenticFinancingStorage.AgreementStatus.Repaid));
        assertTrue(afterRepay.drawTerminated);
    }

    function test_markDelinquent_freezesDraws() public {
        uint256 proposalId = financing.proposeAgreement(11, POSITION_KEY, borrower, provider, 1, 1000, 1, bytes32(0));
        uint256 agreementId = financing.approveAndActivate(proposalId, 1);

        financing.markDelinquent(agreementId, 77);
        LibAgenticFinancingStorage.Agreement memory a = financing.getAgreement(agreementId);
        assertEq(uint8(a.status), uint8(LibAgenticFinancingStorage.AgreementStatus.Delinquent));
        assertTrue(a.drawTerminated);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(AgenticFinancingFacet.AgenticFinancing_DrawTerminated.selector, agreementId));
        financing.applyUsage(agreementId, 1, 0, keccak256("USAGE_BLOCKED"));
    }

    function test_mailbox_publishAndRead_roundtrip() public {
        mailbox.seedAgreement(1, borrower, provider);

        bytes memory borrowerEnvelope = hex"11223344aabbccdd";
        vm.prank(borrower);
        uint256 nonce = mailbox.publishBorrowerPayload(1, borrowerEnvelope);
        assertEq(nonce, 1);

        (address publisher, bytes memory envelope, uint40 publishedAt) = mailbox.getBorrowerPayload(1, 1);
        assertEq(publisher, borrower);
        assertEq(envelope, borrowerEnvelope);
        assertGt(publishedAt, 0);

        vm.prank(address(0x1234));
        vm.expectRevert(AgentMailboxFacet.AgentMailbox_UnauthorizedPublisher.selector);
        mailbox.publishProviderPayload(1, hex"9988");
    }
}

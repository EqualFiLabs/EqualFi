// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAgenticFinancingStorage} from "../libraries/LibAgenticFinancingStorage.sol";

/// @notice Canonical on-chain mailbox payload surface for offchain relayer ingestion.
/// @dev Stores raw encrypted envelope bytes as emitted by clients (phase-1).
contract AgentMailboxFacet {
    error AgentMailbox_InvalidAgreement(uint256 agreementId);
    error AgentMailbox_EmptyEnvelope();
    error AgentMailbox_UnauthorizedPublisher();

    event BorrowerPayloadPublished(uint256 indexed agreementId, address indexed borrower, bytes envelope);
    event ProviderPayloadPublished(uint256 indexed agreementId, address indexed provider, bytes envelope);

    function publishBorrowerPayload(uint256 agreementId, bytes calldata envelope) external returns (uint256 nonce) {
        if (envelope.length == 0) revert AgentMailbox_EmptyEnvelope();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage agreement = ds.agreements[agreementId];
        if (agreement.id == 0) revert AgentMailbox_InvalidAgreement(agreementId);

        if (msg.sender != agreement.borrower && !LibAccess.isOwnerOrTimelock(msg.sender)) {
            revert AgentMailbox_UnauthorizedPublisher();
        }

        nonce = ++ds.borrowerEnvelopeNonce[agreementId];
        ds.borrowerEnvelopes[agreementId][nonce] = LibAgenticFinancingStorage.MailboxEnvelope({
            publisher: msg.sender,
            envelope: envelope,
            publishedAt: uint40(block.timestamp)
        });

        emit BorrowerPayloadPublished(agreementId, msg.sender, envelope);
    }

    function publishProviderPayload(uint256 agreementId, bytes calldata envelope) external returns (uint256 nonce) {
        if (envelope.length == 0) revert AgentMailbox_EmptyEnvelope();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage agreement = ds.agreements[agreementId];
        if (agreement.id == 0) revert AgentMailbox_InvalidAgreement(agreementId);

        if (msg.sender != agreement.provider && !LibAccess.isOwnerOrTimelock(msg.sender)) {
            revert AgentMailbox_UnauthorizedPublisher();
        }

        nonce = ++ds.providerEnvelopeNonce[agreementId];
        ds.providerEnvelopes[agreementId][nonce] = LibAgenticFinancingStorage.MailboxEnvelope({
            publisher: msg.sender,
            envelope: envelope,
            publishedAt: uint40(block.timestamp)
        });

        emit ProviderPayloadPublished(agreementId, msg.sender, envelope);
    }

    function getBorrowerPayload(uint256 agreementId, uint256 nonce)
        external
        view
        returns (address publisher, bytes memory envelope, uint40 publishedAt)
    {
        LibAgenticFinancingStorage.MailboxEnvelope storage e =
            LibAgenticFinancingStorage.layout().borrowerEnvelopes[agreementId][nonce];
        return (e.publisher, e.envelope, e.publishedAt);
    }

    function getProviderPayload(uint256 agreementId, uint256 nonce)
        external
        view
        returns (address publisher, bytes memory envelope, uint40 publishedAt)
    {
        LibAgenticFinancingStorage.MailboxEnvelope storage e =
            LibAgenticFinancingStorage.layout().providerEnvelopes[agreementId][nonce];
        return (e.publisher, e.envelope, e.publishedAt);
    }

    function getMailboxNonces(uint256 agreementId) external view returns (uint256 borrowerNonce, uint256 providerNonce) {
        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        borrowerNonce = ds.borrowerEnvelopeNonce[agreementId];
        providerNonce = ds.providerEnvelopeNonce[agreementId];
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](5);
        selectorsArr[0] = this.publishBorrowerPayload.selector;
        selectorsArr[1] = this.publishProviderPayload.selector;
        selectorsArr[2] = this.getBorrowerPayload.selector;
        selectorsArr[3] = this.getProviderPayload.selector;
        selectorsArr[4] = this.getMailboxNonces.selector;
    }
}

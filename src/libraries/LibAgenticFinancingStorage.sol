// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Diamond storage layout for Synthesis agentic financing primitives.
library LibAgenticFinancingStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.synthesis.agentic.financing.storage");

    enum AgreementStatus {
        None,
        Proposed,
        Active,
        Delinquent,
        Defaulted,
        Repaid,
        Terminated
    }

    enum ProposalType {
        Unknown,
        CreditLine,
        UsageBased
    }

    struct Proposal {
        uint256 id;
        uint256 agentId;
        bytes32 positionKey;
        address borrower;
        address provider;
        ProposalType proposalType;
        uint256 principalRequested;
        uint256 unitsRequested;
        bytes32 metadataHash;
        uint40 createdAt;
        bool approved;
        bool rejected;
    }

    struct Agreement {
        uint256 id;
        uint256 proposalId;
        uint256 agentId;
        bytes32 positionKey;
        address borrower;
        address provider;
        uint256 principalEncumbered;
        uint256 unitsEncumbered;
        AgreementStatus status;
        bool drawTerminated;
        uint40 activatedAt;
        uint40 updatedAt;
    }

    struct MailboxEnvelope {
        address publisher;
        bytes envelope;
        uint40 publishedAt;
    }

    struct Layout {
        uint256 nextProposalId;
        uint256 nextAgreementId;
        mapping(uint256 => Proposal) proposals;
        mapping(uint256 => Agreement) agreements;
        mapping(bytes32 => uint256[]) agreementsByPositionKey;
        mapping(address => uint256[]) agreementsByBorrower;
        mapping(address => uint256[]) agreementsByProvider;
        mapping(uint256 => uint256) borrowerEnvelopeNonce;
        mapping(uint256 => uint256) providerEnvelopeNonce;
        mapping(uint256 => mapping(uint256 => MailboxEnvelope)) borrowerEnvelopes;
        mapping(uint256 => mapping(uint256 => MailboxEnvelope)) providerEnvelopes;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            l.slot := slot
        }
    }
}

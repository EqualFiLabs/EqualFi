// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAgenticFinancingStorage} from "../libraries/LibAgenticFinancingStorage.sol";

/// @notice Native-encumbrance-first lifecycle facet for Synthesis agreements.
/// @dev Phase-1 skeleton: proposal/activation/usage/repay/delinquency/default transitions + canonical events.
contract AgenticFinancingFacet {
    error AgenticFinancing_InvalidAddress();
    error AgenticFinancing_InvalidPositionKey();
    error AgenticFinancing_InvalidProposal(uint256 proposalId);
    error AgenticFinancing_InvalidAgreement(uint256 agreementId);
    error AgenticFinancing_InvalidState(uint8 currentState);
    error AgenticFinancing_NotBorrower();
    error AgenticFinancing_DrawTerminated(uint256 agreementId);

    event ProposalCreated(uint256 indexed proposalId, uint8 proposalType, uint256 indexed agentId);
    event ProposalApproved(uint256 indexed proposalId, address indexed approver);
    event ProposalRejected(uint256 indexed proposalId, address indexed rejector);

    event AgreementActivated(uint256 indexed agreementId, uint256 indexed proposalId, uint8 mode);
    event NativeEncumbranceUpdated(
        uint256 indexed agreementId,
        bytes32 indexed positionKey,
        uint256 principalEncumbered,
        uint256 unitsEncumbered,
        bytes32 reason
    );
    event RepaymentApplied(uint256 indexed agreementId, uint256 amount, uint256 toFees, uint256 toInterest, uint256 toPrincipal);
    event AgreementDelinquent(uint256 indexed agreementId, uint256 pastDue);
    event DrawRightsTerminated(uint256 indexed agreementId, bytes32 reason);
    event AgreementDefaulted(uint256 indexed agreementId, uint256 pastDue);
    event AgreementTerminated(uint256 indexed agreementId, bytes32 reason);

    function proposeAgreement(
        uint256 agentId,
        bytes32 positionKey,
        address borrower,
        address provider,
        uint8 proposalType,
        uint256 principalRequested,
        uint256 unitsRequested,
        bytes32 metadataHash
    ) external returns (uint256 proposalId) {
        if (borrower == address(0) || provider == address(0)) revert AgenticFinancing_InvalidAddress();
        if (positionKey == bytes32(0)) revert AgenticFinancing_InvalidPositionKey();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        proposalId = ++ds.nextProposalId;

        LibAgenticFinancingStorage.Proposal storage p = ds.proposals[proposalId];
        p.id = proposalId;
        p.agentId = agentId;
        p.positionKey = positionKey;
        p.borrower = borrower;
        p.provider = provider;
        p.proposalType = LibAgenticFinancingStorage.ProposalType(proposalType);
        p.principalRequested = principalRequested;
        p.unitsRequested = unitsRequested;
        p.metadataHash = metadataHash;
        p.createdAt = uint40(block.timestamp);

        emit ProposalCreated(proposalId, proposalType, agentId);
    }

    function approveAndActivate(uint256 proposalId, uint8 mode) external returns (uint256 agreementId) {
        LibAccess.enforceOwnerOrTimelock();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Proposal storage p = ds.proposals[proposalId];

        if (p.id == 0 || p.rejected || p.approved) revert AgenticFinancing_InvalidProposal(proposalId);

        p.approved = true;
        emit ProposalApproved(proposalId, msg.sender);

        agreementId = ++ds.nextAgreementId;
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        a.id = agreementId;
        a.proposalId = proposalId;
        a.agentId = p.agentId;
        a.positionKey = p.positionKey;
        a.borrower = p.borrower;
        a.provider = p.provider;
        a.principalEncumbered = p.principalRequested;
        a.unitsEncumbered = p.unitsRequested;
        a.status = LibAgenticFinancingStorage.AgreementStatus.Active;
        a.activatedAt = uint40(block.timestamp);
        a.updatedAt = uint40(block.timestamp);

        ds.agreementsByPositionKey[a.positionKey].push(agreementId);
        ds.agreementsByBorrower[a.borrower].push(agreementId);
        ds.agreementsByProvider[a.provider].push(agreementId);

        emit AgreementActivated(agreementId, proposalId, mode);
        emit NativeEncumbranceUpdated(
            agreementId, a.positionKey, a.principalEncumbered, a.unitsEncumbered, keccak256("ACTIVATION")
        );
    }

    function rejectProposal(uint256 proposalId) external {
        LibAccess.enforceOwnerOrTimelock();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Proposal storage p = ds.proposals[proposalId];
        if (p.id == 0 || p.approved || p.rejected) revert AgenticFinancing_InvalidProposal(proposalId);

        p.rejected = true;
        emit ProposalRejected(proposalId, msg.sender);
    }

    function applyUsage(uint256 agreementId, uint256 principalDelta, uint256 unitsDelta, bytes32 reason) external {
        LibAgenticFinancingStorage.Agreement storage a = _activeAgreementForUpdate(agreementId);

        // Provider and governance are both allowed to report usage in phase-1.
        if (msg.sender != a.provider && !LibAccess.isOwnerOrTimelock(msg.sender)) {
            revert AgenticFinancing_InvalidAddress();
        }

        a.principalEncumbered += principalDelta;
        a.unitsEncumbered += unitsDelta;
        a.updatedAt = uint40(block.timestamp);

        emit NativeEncumbranceUpdated(agreementId, a.positionKey, a.principalEncumbered, a.unitsEncumbered, reason);
    }

    function repay(uint256 agreementId, uint256 amount) external {
        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        if (a.id == 0) revert AgenticFinancing_InvalidAgreement(agreementId);

        LibAgenticFinancingStorage.AgreementStatus status = a.status;
        if (
            status != LibAgenticFinancingStorage.AgreementStatus.Active
                && status != LibAgenticFinancingStorage.AgreementStatus.Delinquent
        ) {
            revert AgenticFinancing_InvalidState(uint8(status));
        }

        if (msg.sender != a.borrower && !LibAccess.isOwnerOrTimelock(msg.sender)) {
            revert AgenticFinancing_NotBorrower();
        }

        uint256 toPrincipal = amount > a.principalEncumbered ? a.principalEncumbered : amount;
        a.principalEncumbered -= toPrincipal;
        a.updatedAt = uint40(block.timestamp);

        if (a.principalEncumbered == 0) {
            a.status = LibAgenticFinancingStorage.AgreementStatus.Repaid;
            a.drawTerminated = true;
        }

        emit RepaymentApplied(agreementId, amount, 0, 0, toPrincipal);
        emit NativeEncumbranceUpdated(
            agreementId,
            a.positionKey,
            a.principalEncumbered,
            a.unitsEncumbered,
            keccak256("REPAYMENT_APPLIED")
        );
    }

    function markDelinquent(uint256 agreementId, uint256 pastDue) external {
        LibAccess.enforceOwnerOrTimelock();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        if (a.id == 0) revert AgenticFinancing_InvalidAgreement(agreementId);

        LibAgenticFinancingStorage.AgreementStatus status = a.status;
        if (
            status != LibAgenticFinancingStorage.AgreementStatus.Active
                && status != LibAgenticFinancingStorage.AgreementStatus.Delinquent
        ) {
            revert AgenticFinancing_InvalidState(uint8(status));
        }

        a.status = LibAgenticFinancingStorage.AgreementStatus.Delinquent;
        if (!a.drawTerminated) {
            a.drawTerminated = true;
            emit DrawRightsTerminated(agreementId, keccak256("DELINQUENCY"));
        }
        a.updatedAt = uint40(block.timestamp);

        emit AgreementDelinquent(agreementId, pastDue);
    }

    function markDefaulted(uint256 agreementId, uint256 pastDue, bytes32 reason) external {
        LibAccess.enforceOwnerOrTimelock();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        if (a.id == 0) revert AgenticFinancing_InvalidAgreement(agreementId);

        LibAgenticFinancingStorage.AgreementStatus status = a.status;
        if (
            status != LibAgenticFinancingStorage.AgreementStatus.Active
                && status != LibAgenticFinancingStorage.AgreementStatus.Delinquent
        ) {
            revert AgenticFinancing_InvalidState(uint8(status));
        }

        a.status = LibAgenticFinancingStorage.AgreementStatus.Defaulted;
        if (!a.drawTerminated) {
            a.drawTerminated = true;
            emit DrawRightsTerminated(agreementId, reason);
        }
        a.updatedAt = uint40(block.timestamp);

        emit AgreementDefaulted(agreementId, pastDue);
    }

    function terminateAgreement(uint256 agreementId, bytes32 reason) external {
        LibAccess.enforceOwnerOrTimelock();

        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        LibAgenticFinancingStorage.Agreement storage a = ds.agreements[agreementId];
        if (a.id == 0) revert AgenticFinancing_InvalidAgreement(agreementId);

        LibAgenticFinancingStorage.AgreementStatus status = a.status;
        if (
            status != LibAgenticFinancingStorage.AgreementStatus.Active
                && status != LibAgenticFinancingStorage.AgreementStatus.Delinquent
                && status != LibAgenticFinancingStorage.AgreementStatus.Defaulted
        ) {
            revert AgenticFinancing_InvalidState(uint8(status));
        }

        a.status = LibAgenticFinancingStorage.AgreementStatus.Terminated;
        if (!a.drawTerminated) {
            a.drawTerminated = true;
            emit DrawRightsTerminated(agreementId, reason);
        }
        a.updatedAt = uint40(block.timestamp);

        emit AgreementTerminated(agreementId, reason);
    }

    function getProposal(uint256 proposalId) external view returns (LibAgenticFinancingStorage.Proposal memory) {
        return LibAgenticFinancingStorage.layout().proposals[proposalId];
    }

    function getAgreement(uint256 agreementId) external view returns (LibAgenticFinancingStorage.Agreement memory) {
        return LibAgenticFinancingStorage.layout().agreements[agreementId];
    }

    function getAgreementsByPositionKey(bytes32 positionKey) external view returns (uint256[] memory) {
        return LibAgenticFinancingStorage.layout().agreementsByPositionKey[positionKey];
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](11);
        selectorsArr[0] = this.proposeAgreement.selector;
        selectorsArr[1] = this.approveAndActivate.selector;
        selectorsArr[2] = this.rejectProposal.selector;
        selectorsArr[3] = this.applyUsage.selector;
        selectorsArr[4] = this.repay.selector;
        selectorsArr[5] = this.markDelinquent.selector;
        selectorsArr[6] = this.markDefaulted.selector;
        selectorsArr[7] = this.terminateAgreement.selector;
        selectorsArr[8] = this.getProposal.selector;
        selectorsArr[9] = this.getAgreement.selector;
        selectorsArr[10] = this.getAgreementsByPositionKey.selector;
    }

    function _activeAgreementForUpdate(uint256 agreementId)
        internal
        view
        returns (LibAgenticFinancingStorage.Agreement storage a)
    {
        LibAgenticFinancingStorage.Layout storage ds = LibAgenticFinancingStorage.layout();
        a = ds.agreements[agreementId];
        if (a.id == 0) revert AgenticFinancing_InvalidAgreement(agreementId);

        if (a.drawTerminated) revert AgenticFinancing_DrawTerminated(agreementId);
        if (a.status != LibAgenticFinancingStorage.AgreementStatus.Active) {
            revert AgenticFinancing_InvalidState(uint8(a.status));
        }
    }
}

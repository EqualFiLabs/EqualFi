// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibDirectHelpers} from "../../src/libraries/LibDirectHelpers.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibAccess} from "../../src/libraries/LibAccess.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {DirectError_InvalidOffer} from "../../src/libraries/Errors.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Test view facet with read-only helpers for direct lending tests
/// @dev Deployed as a separate facet to avoid stack-too-deep when combined with other facets
contract DirectTestViewFacet {
    function trancheRemaining(uint256 offerId) external view returns (uint256) {
        return LibDirectStorage.directStorage().trancheRemaining[offerId];
    }

    function offerEscrow(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directOfferEscrow;
    }

    function enforceFixedSizeFills() external view returns (bool) {
        return LibDirectStorage.directStorage().enforceFixedSizeFills;
    }

    function directCounters() external view returns (uint256 nextOfferId, uint256 nextAgreementId) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        return (ds.nextOfferId, ds.nextAgreementId);
    }

    function positionState(bytes32 positionKey, uint256 pid) external view returns (DirectTypes.PositionDirectState memory) {
        return LibDirectStorage.positionState(positionKey, pid);
    }

    function borrowerAgreementsPage(bytes32 borrowerKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements, uint256 total)
    {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        return LibDirectStorage.borrowerAgreementsPage(ds, borrowerKey, offset, limit);
    }

    function activeCreditPoolView(uint256 pid)
        external
        view
        returns (uint256 totalDeposits, uint256 index, uint256 remainder)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.totalDeposits, p.activeCreditIndex, p.activeCreditIndexRemainder);
    }

    function pendingYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibActiveCreditIndex.pendingYield(pid, user);
    }

    function encumbranceActiveCreditState(uint256 pid, bytes32 user)
        external
        view
        returns (Types.ActiveCreditState memory)
    {
        return LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
    }

    function activeCreditWeight(uint256 pid, bytes32 user) external view returns (uint256) {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return LibActiveCreditIndex.activeWeight(state);
    }

    function activeCreditTimeCredit(uint256 pid, bytes32 user) external view returns (uint256) {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return LibActiveCreditIndex.timeCredit(state);
    }

    function directLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function directBorrowed(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid];
    }

    function activeCreditEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[positionKey].principal;
    }

    function activeCreditDebt(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateDebt[positionKey].principal;
    }

    function poolActiveCreditTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function poolActiveCreditIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndex;
    }

    function getDirectConfig() external view returns (DirectTypes.DirectConfig memory) {
        return LibDirectStorage.directStorage().config;
    }

    function setDirectConfig(DirectTypes.DirectConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDirectHelpers._validateConfig(config);
        LibDirectStorage.directStorage().config = config;
    }

    function poolState(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 activeCreditIndex)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        principal = p.userPrincipal[positionKey];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        feeIndex = p.feeIndex;
        activeCreditIndex = p.activeCreditIndex;
    }

    function sameAssetDebt(bytes32 borrower, address asset) external view returns (uint256) {
        return LibDirectStorage.directStorage().directSameAssetDebt[borrower][asset];
    }

    function agreementStatus(uint256 id) external view returns (DirectTypes.DirectStatus) {
        return LibDirectStorage.directStorage().agreements[id].status;
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function poolTotals(uint256 pid) external view returns (uint256 totalDeposits, uint256 feeIndex) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.totalDeposits, p.feeIndex);
    }

    function poolTracked(uint256 pid) external view returns (uint256 trackedBalance, uint256 activeCreditIndex) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.trackedBalance, p.activeCreditIndex);
    }

    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function activeDebtState(uint256 pid, bytes32 user) external view returns (Types.ActiveCreditState memory) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateDebt[user];
    }

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getTotalDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function getWithdrawablePrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateWithdrawablePrincipal(p, positionKey, pid);
    }

    function getDirectOfferEscrow(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directOfferEscrow;
    }

    function getActiveDirectLent(uint256 pid) external view returns (uint256) {
        return LibDirectStorage.directStorage().activeDirectLentPerPool[pid];
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function pendingActiveCredit(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibActiveCreditIndex.pendingActiveCredit(pid, user);
    }

    function getActiveCreditIndex(uint256 pid)
        external
        view
        returns (uint256 index, uint256 remainder, uint256 activePrincipalTotal)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.activeCreditIndex, p.activeCreditIndexRemainder, p.activeCreditPrincipalTotal);
    }

    function getAgreement(uint256 agreementId) external view returns (DirectTypes.DirectAgreement memory) {
        return LibDirectStorage.directStorage().agreements[agreementId];
    }

    function getBorrowerOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerOffer memory) {
        return LibDirectStorage.directStorage().borrowerOffers[offerId];
    }

    function getOffer(uint256 offerId) external view returns (DirectTypes.DirectOffer memory) {
        return LibDirectStorage.directStorage().offers[offerId];
    }

    function getBorrowerAgreements(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements)
    {
        bytes32 positionKey = LibDirectHelpers._positionNFT().getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (agreements,) = LibDirectStorage.borrowerAgreementsPage(ds, positionKey, offset, limit);
    }

    function directLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectRatioTrancheOffer memory) {
        return LibDirectStorage.directStorage().ratioOffers[offerId];
    }

    function getBorrowerRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerRatioTrancheOffer memory) {
        return LibDirectStorage.directStorage().borrowerRatioOffers[offerId];
    }

    function getOfferTranche(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        return _trancheStatus(offerId);
    }

    function getTrancheStatus(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        return _trancheStatus(offerId);
    }

    function isTrancheOffer(uint256 offerId) external view returns (bool) {
        DirectTypes.DirectOffer storage offer = LibDirectStorage.directStorage().offers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();
        return offer.isTranche;
    }

    function fillsRemaining(uint256 offerId) external view returns (uint256) {
        return _trancheStatus(offerId).fillsRemaining;
    }

    function isTrancheDepleted(uint256 offerId) external view returns (bool) {
        return _trancheStatus(offerId).isDepleted;
    }

    function getPositionDirectState(uint256 positionId, uint256 poolId)
        external
        view
        returns (uint256 locked, uint256 lent)
    {
        bytes32 positionKey = LibDirectHelpers._positionNFT().getPositionKey(positionId);
        DirectTypes.PositionDirectState memory state = LibDirectStorage.positionState(positionKey, poolId);
        return (state.directLockedPrincipal, state.directLentPrincipal);
    }

    function directBalances(bytes32 key, uint256 pid) external view returns (uint256 locked, uint256 lent, uint256 borrowed) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        locked = LibEncumbrance.position(key, pid).directLocked;
        lent = LibEncumbrance.position(key, pid).directLent;
        borrowed = ds.directBorrowedPrincipal[key][pid];
    }

    function _trancheStatus(uint256 offerId) internal view returns (DirectTypes.DirectTrancheView memory viewData) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();
        uint256 trancheRemaining = offer.isTranche ? ds.trancheRemaining[offerId] : 0;
        bool isDepleted = offer.isTranche ? trancheRemaining == 0 : (offer.cancelled || offer.filled);
        uint256 fills = offer.isTranche ? trancheRemaining / offer.principal : (isDepleted ? 0 : 1);

        viewData = DirectTypes.DirectTrancheView({
            isTranche: offer.isTranche,
            trancheAmount: offer.trancheAmount,
            trancheRemaining: trancheRemaining,
            principalPerFill: offer.principal,
            fillsRemaining: fills,
            isDepleted: isDepleted,
            cancelled: offer.cancelled,
            filled: offer.filled
        });
    }
}

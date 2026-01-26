// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectAgreementFacet} from "../../src/equallend-direct/EqualLendDirectAgreementFacet.sol";
import {EqualLendDirectLifecycleFacet} from "../../src/equallend-direct/EqualLendDirectLifecycleFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibDirectHelpers} from "../../src/libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Test harness that composes direct facets into a single contract
/// @dev EqualLendDirectViewFacet excluded to avoid stack-too-deep with large structs
/// @dev Large struct getters moved to individual test harnesses as needed
contract DirectFacetHarness is
    EqualLendDirectOfferFacet,
    EqualLendDirectAgreementFacet,
    EqualLendDirectLifecycleFacet
{
    /// @notice Set direct config (moved from ViewFacet to avoid stack-too-deep)
    function setDirectConfig(DirectTypes.DirectConfig calldata config) external {
        LibDirectHelpers._validateConfig(config);
        LibDirectStorage.directStorage().config = config;
    }

    /// @notice Get agreement by ID - virtual so child harnesses can override if needed
    function getAgreement(uint256 agreementId) external view virtual returns (DirectTypes.DirectAgreement memory) {
        return LibDirectStorage.directStorage().agreements[agreementId];
    }

    /// @notice Get borrower offer by ID - virtual so child harnesses can override if needed
    function getBorrowerOffer(uint256 offerId) external view virtual returns (DirectTypes.DirectBorrowerOffer memory) {
        return LibDirectStorage.directStorage().borrowerOffers[offerId];
    }

    /// @notice Get offer by ID - virtual so child harnesses can override if needed
    function getOffer(uint256 offerId) external view virtual returns (DirectTypes.DirectOffer memory) {
        return LibDirectStorage.directStorage().offers[offerId];
    }

    /// @notice Get position direct state
    function getPositionDirectState(uint256 positionId, uint256 poolId)
        external
        view
        returns (uint256 locked, uint256 lent)
    {
        bytes32 positionKey = LibDirectHelpers._positionNFT().getPositionKey(positionId);
        DirectTypes.PositionDirectState memory state = LibDirectStorage.positionState(positionKey, poolId);
        return (state.directLockedPrincipal, state.directLentPrincipal);
    }

    /// @notice Get borrower agreements for a position (returns only array, matching original)
    function getBorrowerAgreements(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements)
    {
        bytes32 positionKey = LibDirectHelpers._positionNFT().getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (agreements,) = LibDirectStorage.borrowerAgreementsPage(ds, positionKey, offset, limit);
    }

    /// @notice Get pool active direct lent
    function getPoolActiveDirectLent(uint256 poolId) external view returns (uint256) {
        return LibDirectStorage.directStorage().activeDirectLentPerPool[poolId];
    }

    /// @notice Check if offer is a tranche offer
    function isTrancheOffer(uint256 offerId) external view returns (bool) {
        return LibDirectStorage.directStorage().offers[offerId].isTranche;
    }

    /// @notice Get fills remaining for a tranche offer
    function fillsRemaining(uint256 offerId) external view returns (uint256) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (!offer.isTranche) return offer.cancelled || offer.filled ? 0 : 1;
        uint256 trancheRemaining = ds.trancheRemaining[offerId];
        return trancheRemaining / offer.principal;
    }

    /// @notice Check if tranche is depleted
    function isTrancheDepleted(uint256 offerId) external view returns (bool) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (!offer.isTranche) return offer.cancelled || offer.filled;
        return ds.trancheRemaining[offerId] == 0;
    }

    /// @notice Get offer tranche status
    function getOfferTranche(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        uint256 trancheRemaining = offer.isTranche ? ds.trancheRemaining[offerId] : 0;
        bool isDepleted = offer.isTranche ? trancheRemaining == 0 : (offer.cancelled || offer.filled);
        uint256 fills = offer.isTranche ? trancheRemaining / offer.principal : (isDepleted ? 0 : 1);
        return DirectTypes.DirectTrancheView({
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

    /// @notice Get tranche status (alias)
    function getTrancheStatus(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        uint256 trancheRemaining = offer.isTranche ? ds.trancheRemaining[offerId] : 0;
        bool isDepleted = offer.isTranche ? trancheRemaining == 0 : (offer.cancelled || offer.filled);
        uint256 fills = offer.isTranche ? trancheRemaining / offer.principal : (isDepleted ? 0 : 1);
        return DirectTypes.DirectTrancheView({
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

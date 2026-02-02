// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDirectStorage} from "../src/libraries/LibDirectStorage.sol";
import {DirectTypes} from "../src/libraries/DirectTypes.sol";
import {LibEncumbrance} from "../src/libraries/LibEncumbrance.sol";
import {LibActiveCreditIndex} from "../src/libraries/LibActiveCreditIndex.sol";
import {LibPositionList} from "../src/libraries/LibPositionList.sol";

/// @notice Stateful fuzzing for LibDirectStorage offer tracking and cancellation
contract EchidnaDirectStorage {
    using LibPositionList for LibPositionList.List;
    bytes32 internal constant TEST_POSITION = keccak256("test.position");
    uint256 internal constant TEST_POOL = 1;
    
    // Track ghost state for list counts
    uint256 internal ghost_lenderOffers;
    uint256 internal ghost_borrowerOffers;
    
    // Mock accounting
    uint256 internal ghost_escrow;
    uint256 internal ghost_locked;

    // ========== ACTIONS ==========

    /// @notice Simulate creating a Lender Offer
    function action_createLenderOffer(uint256 offerId, uint128 amount) public {
        if (offerId == 0) return;
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        
        // Mock the offer struct
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lenderPositionId != 0) return; // Already exists
        
        offer.lenderPositionId = uint256(TEST_POSITION); // Mock ID
        offer.lenderPoolId = TEST_POOL;
        offer.principal = amount;
        offer.cancelled = false;
        offer.filled = false;
        
        LibDirectStorage.trackLenderOffer(ds, TEST_POSITION, offerId);
        ghost_lenderOffers++;
        
        // Simulate encumbrance (normally done by facade)
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(TEST_POSITION, TEST_POOL);
        enc.directOfferEscrow += amount;
        ghost_escrow += amount;
    }

    /// @notice Simulate creating a Borrower Offer
    function action_createBorrowerOffer(uint256 offerId, uint128 collateralAmount) public {
        if (offerId == 0) return;
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        
        DirectTypes.DirectBorrowerOffer storage offer = ds.borrowerOffers[offerId];
        if (offer.borrowerPositionId != 0) return;
        
        offer.borrowerPositionId = uint256(TEST_POSITION);
        offer.collateralPoolId = TEST_POOL;
        offer.collateralLockAmount = collateralAmount;
        offer.cancelled = false;
        offer.filled = false;
        
        LibDirectStorage.trackBorrowerOffer(ds, TEST_POSITION, offerId);
        ghost_borrowerOffers++;
        
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(TEST_POSITION, TEST_POOL);
        enc.directLocked += collateralAmount;
        ghost_locked += collateralAmount;
    }

    /// @notice Cancel all offers (Transition)
    function action_cancelAll() public {
        // This function in library iterates lists and clears them
        LibDirectStorage.cancelOffersForPosition(TEST_POSITION);
        
        // Reset ghosts
        ghost_lenderOffers = 0;
        ghost_borrowerOffers = 0;
        ghost_escrow = 0;
        ghost_locked = 0;
    }

    // ========== INVARIANTS ==========

    /// @notice Verify hasOutstandingOffers matches ghost counts
    function echidna_offers_flag_consistency() public view returns (bool) {
        bool hasOffers = LibDirectStorage.hasOutstandingOffers(TEST_POSITION);
        bool expected = (ghost_lenderOffers > 0 || ghost_borrowerOffers > 0);
        return hasOffers == expected;
    }

    /// @notice Verify encumbrance is cleared after cancelAll
    /// (Checked implicitly because if cancelAll runs, ghosts are 0, so if library fails to clear,
    /// next check of total encumbrance vs ghost will fail? No, we need explicit check)
    function echidna_encumbrance_matches_ghost() public view returns (bool) {
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(TEST_POSITION, TEST_POOL);
        return enc.directOfferEscrow == ghost_escrow && enc.directLocked == ghost_locked;
    }
    
    /// @notice Check internal list consistency
    function echidna_list_counts_match() public view returns (bool) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (,, uint256 lenderCount) = ds.lenderOffers.meta(TEST_POSITION);
        (,, uint256 borrowerCount) = ds.borrowerOffersByPosition.meta(TEST_POSITION);
        
        return lenderCount == ghost_lenderOffers && borrowerCount == ghost_borrowerOffers;
    }
}

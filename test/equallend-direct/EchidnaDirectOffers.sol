// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {DirectTestHarnessFacet} from "./DirectTestHarnessFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockPositionNFT} from "../../src/mocks/MockPositionNFT.sol";

contract EchidnaDirectOffers is DirectTestHarnessFacet {
    EqualLendDirectOfferFacet internal offerFacet;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockPositionNFT internal nft;

    uint256 internal constant WETH_POOL_ID = 1;
    uint256 internal constant USDC_POOL_ID = 2;
    uint256 internal lenderPositionId = 1;
    uint256 internal borrowerPositionId = 2;
    bytes32 internal lenderKey;
    bytes32 internal borrowerKey;

    constructor() {
        // Setup done in setup()
    }

    function setup() public {
        weth = new MockERC20("WETH", "WETH", 18, 1_000_000e18);
        usdc = new MockERC20("USDC", "USDC", 6, 1_000_000e6);
        nft = new MockPositionNFT();
        offerFacet = new EqualLendDirectOfferFacet();

        // Configure NFT storage
        this.configurePositionNFT(address(nft));

        // Initialize pools
        this.initPool(WETH_POOL_ID, address(weth));
        this.initPool(USDC_POOL_ID, address(usdc));

        // Create and mint positions
        nft.mint(address(this), lenderPositionId);
        nft.mint(address(this), borrowerPositionId);

        // Derive keys (using MockPositionNFT logic + lib assumption)
        lenderKey = keccak256(abi.encode(lenderPositionId, address(nft)));
        borrowerKey = keccak256(abi.encode(borrowerPositionId, address(nft)));

        // Fund positions
        this.seedPosition(WETH_POOL_ID, lenderKey, 1000e18); // Lender has WETH
        this.seedPosition(USDC_POOL_ID, borrowerKey, 1000e6); // Borrower has USDC collateral
        
        // Mint tokens to this contract (vault)
        weth.mint(address(this), 2000e18);
        usdc.mint(address(this), 2000e6);
    }

    // --- Actions ---

    function createLenderOffer(
        uint256 principal,
        uint256 collateralAmount,
        uint32 duration,
        uint16 aprBps
    ) public {
        principal = (principal % 100e18) + 1e18;
        collateralAmount = (collateralAmount % 1000e6) + 1e6;
        duration = (duration % 365 days) + 1 days;
        aprBps = aprBps % 1000; // 0-10%

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: WETH_POOL_ID,
            collateralPoolId: USDC_POOL_ID,
            collateralAsset: address(usdc), // Added
            borrowAsset: address(weth),     // Added
            principal: principal,
            collateralLockAmount: collateralAmount,
            durationSeconds: duration,
            aprBps: aprBps,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        // Use abi.encodeWithSignature to disambiguate overloaded function
        (bool success, ) = address(offerFacet).delegatecall(
            abi.encodeWithSignature("postOffer((uint256,uint256,uint256,address,address,uint256,uint16,uint64,uint256,bool,bool,bool))", params)
        );
        // Ignore failure, fuzzer finds valid inputs
    }

    function createBorrowerOffer(
        uint256 principal,
        uint256 collateralAmount,
        uint32 duration,
        uint16 aprBps
    ) public {
        principal = (principal % 100e18) + 1e18;
        collateralAmount = (collateralAmount % 1000e6) + 1e6;
        duration = (duration % 365 days) + 1 days;
        aprBps = aprBps % 1000;

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: WETH_POOL_ID,
            collateralPoolId: USDC_POOL_ID,
            collateralAsset: address(usdc), // Added
            borrowAsset: address(weth),     // Added
            principal: principal,
            collateralLockAmount: collateralAmount,
            durationSeconds: duration,
            aprBps: aprBps,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        (bool success, ) = address(offerFacet).delegatecall(
            abi.encodeWithSelector(EqualLendDirectOfferFacet.postBorrowerOffer.selector, params)
        );
    }

    function cancelOffer(uint256 offerId) public {
        if (offerId == 0) return;
        // Try to cancel as lender
        (bool success, ) = address(offerFacet).delegatecall(
            abi.encodeWithSelector(EqualLendDirectOfferFacet.cancelOffer.selector, offerId, lenderPositionId)
        );
    }

    // --- Invariants ---

    // 1. Offer Integrity: Active offers must have valid amounts
    function echidna_offer_integrity() public view returns (bool) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 offerId = ds.nextOfferId;
        if (offerId == 0) return true;

        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        // Check cancel/filled status instead of "active"
        if (!offer.cancelled && !offer.filled) {
            return offer.principal > 0 && offer.collateralLockAmount > 0;
        }
        return true;
    }

    // 2. Encumbrance: Creating a borrower offer should encumber collateral
    function echidna_borrower_encumbrance() public view returns (bool) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        // Iterate last offer
        uint256 offerId = ds.nextOfferId;
        if (offerId == 0) return true;
        
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        // If borrower offer (isOffer=false in some contexts, but here stored in same struct)
        // Actually DirectOffer struct doesn't strictly say who created it, but the key does.
        if (!offer.cancelled && !offer.filled && offer.lenderPositionId == borrowerPositionId) {
            uint256 enc = LibEncumbrance.position(borrowerKey, USDC_POOL_ID).directOfferEscrow;
            // Encumbrance should be at least this offer amount (could be more if multiple offers)
            return enc >= offer.collateralLockAmount;
        }
        return true;
    }
}

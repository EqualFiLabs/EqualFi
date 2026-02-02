// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../../src/EqualX/MamCurveManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {LibDirectHelpers} from "../../src/libraries/LibDirectHelpers.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";

// Mock NFT to satisfy ownership and key derivation checks
contract MockPositionNFTMam {
    function ownerOf(uint256) external view returns (address) {
        return msg.sender; // Everything is owned by the harness
    }
    // LibPositionNFT mock logic if accessed directly
}

contract EchidnaMamFull is MamCurveExecutionFacet, MamCurveCreationFacet, MamCurveManagementFacet {
    MockERC20 internal tokenBase;
    MockERC20 internal tokenQuote;
    MockPositionNFTMam internal mockNft;
    
    uint256 internal constant PID_BASE = 1;
    uint256 internal constant PID_QUOTE = 2;
    uint256 internal constant MAKER_ID = 100;
    bytes32 internal makerKey;
    
    // We assume LibDirectHelpers._positionNFT() calls storage. We must mock that.
    // But since we can't easily replace the internal helper logic, 
    // we rely on the fact that LibDirectHelpers._requirePositionOwnership calls nft.ownerOf(tokenId).
    // Our MockPositionNFTMam will return msg.sender.
    
    constructor() {
        // Setup done in setup() for Echidna
    }

    function setup() public {
        tokenBase = new MockERC20("Base", "BASE", 18, 1_000_000 ether);
        tokenQuote = new MockERC20("Quote", "QUOTE", 18, 1_000_000 ether);
        mockNft = new MockPositionNFTMam();
        
        // Mock LibPositionNFT storage
        // We can't access LibPositionNFT storage directly as it's a library storage pattern.
        // We need a helper facet or cheat (if local) to set it.
        // Since we are the contract, we can write to our own storage slot if we know it.
        // LibPositionNFT storage slot: keccak256("equalis.storage.position.nft")
        bytes32 slot = keccak256("equalis.storage.position.nft");
        address nftAddr = address(mockNft);
        assembly {
            sstore(slot, nftAddr) // positionNFTContract is 1st slot
            sstore(add(slot, 1), 1) // nftModeEnabled is 2nd slot (bool)
        }

        // Initialize Pools
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        // Base Pool
        Types.PoolData storage pBase = s.pools[PID_BASE];
        pBase.initialized = true;
        pBase.underlying = address(tokenBase);
        pBase.totalDeposits = 1_000_000 ether;
        pBase.trackedBalance = 1_000_000 ether;
        pBase.feeIndex = LibFeeIndex.INDEX_SCALE;
        pBase.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        
        // Quote Pool
        Types.PoolData storage pQuote = s.pools[PID_QUOTE];
        pQuote.initialized = true;
        pQuote.underlying = address(tokenQuote);
        pQuote.feeIndex = LibFeeIndex.INDEX_SCALE;
        pQuote.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        
        // Setup Maker Position
        // We need the key derived by LibPositionNFT.positionKey(MAKER_ID).
        // Since nftModeEnabled is true, key = keccak256(abi.encode(MAKER_ID, nftAddr))
        makerKey = keccak256(abi.encode(MAKER_ID, nftAddr));
        
        pBase.userPrincipal[makerKey] = 1_000_000 ether;
        LibPoolMembership._joinPool(makerKey, PID_BASE);
        LibPoolMembership._joinPool(makerKey, PID_QUOTE);
        
        // Fund contract
        tokenBase.mint(address(this), 1_000_000 ether); // Vault balance
        tokenQuote.mint(address(this), 1_000_000 ether); // Taker balance
    }
    
    // ========== ACTIONS ==========

    function createCurve(
        uint128 amount, 
        uint256 startPrice, 
        uint256 endPrice, 
        uint32 duration
    ) public {
        amount = uint128(amount % 1000 ether) + 1 ether;
        startPrice = (startPrice % 100e18) + 0.1e18; // 0.1 to 100
        endPrice = (endPrice % startPrice); // end <= start (Dutch)
        duration = (duration % 7 days) + 1 hours;
        
        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionId: MAKER_ID,
            poolIdA: PID_BASE,
            poolIdB: PID_QUOTE,
            startPrice: uint128(startPrice),
            endPrice: uint128(endPrice),
            startTime: uint64(block.timestamp),
            duration: duration,
            maxVolume: amount,
            feeRateBps: 100, // 1%
            feeAsset: MamTypes.FeeAsset.TokenIn,
            side: true, // Sell Base
            priceIsQuotePerBase: true,
            generation: 0,
            salt: uint96(0),
            makerPositionKey: bytes32(0), // Ignored/Resolved in facet
            tokenA: address(0), // Resolved in facet
            tokenB: address(0)
        });
        
        // Call internally as we inherit the facet logic
        // But facets use internal libraries that assume DELEGATECALL context from Diamond.
        // We are the Diamond in this test harness.
        // We can call `this.createCurve(...)` to trigger external call path (via fallback/delegatecall if we were proxy)
        // OR simply call the internal implementation if exposed.
        // But `createCurve` is external in facet.
        // Since we inherit `MamCurveCreationFacet`, `this.createCurve` is a valid external call to self.
        
        try this.createCurve(desc) {
            // Success
        } catch {
            // Ignore
        }
    }
    
    function cancelCurveAction(uint256 curveId) public {
        if (curveId == 0) return;
        try this.cancelCurve(curveId) {
            // Success
        } catch {
            // Ignore
        }
    }
    
    function updateCurve(uint256 curveId, uint256 newStartPrice) public {
        if (curveId == 0) return;
        newStartPrice = (newStartPrice % 100e18) + 0.1e18;
        
        // Manual struct init due to size
        MamTypes.CurveUpdateParams memory update;
        update.startPrice = uint128(newStartPrice);
        update.endPrice = uint128(newStartPrice / 2);
        update.startTime = uint64(block.timestamp);
        update.duration = 1 days;
        
        try this.updateCurve(curveId, update) {
            // Success
        } catch {
            // Ignore
        }
    }

    function swap(uint256 curveId, uint128 amountIn) public {
        if (curveId == 0) return;
        if (amountIn == 0) return;
        amountIn = amountIn % 100 ether;
        
        // Self-approve quote tokens for swap
        tokenQuote.approve(address(this), amountIn);
        
        try this.executeCurveSwap(
            curveId,
            amountIn,
            0,
            uint64(block.timestamp + 1 days),
            address(this)
        ) {
            // Success
        } catch {
            // Ignore
        }
    }

    // ========== INVARIANTS ==========

    /// @notice Curve consistency: Active curves must have volume > 0 (unless just filled)
    /// Actually, execution checks this.
    /// Invariant: Locked encumbrance matches sum of remaining volumes for maker.
    function echidna_encumbrance_matches_volume() public view returns (bool) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        // Iterate a few curves (Echidna can't loop all easily)
        // We check the last created curve
        uint256 curveId = ds.nextCurveId;
        if (curveId == 0) return true;
        
        MamTypes.StoredCurve storage curve = ds.curves[curveId];
        // If active, encumbrance must match
        if (curve.active) {
            uint256 enc = LibEncumbrance.getIndexEncumberedForIndex(makerKey, PID_BASE, curveId);
            return enc == curve.remainingVolume;
        } else {
            // If inactive/cancelled, encumbrance should be 0
            uint256 enc = LibEncumbrance.getIndexEncumberedForIndex(makerKey, PID_BASE, curveId);
            return enc == 0;
        }
    }
    
    /// @notice Maker solvency: Principal >= Total Encumbered
    function echidna_maker_solvency() public view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID_BASE];
        
        uint256 principal = p.userPrincipal[makerKey];
        uint256 encumbered = LibEncumbrance.totalForActiveCredit(makerKey, PID_BASE);
        
        return principal >= encumbered;
    }
}

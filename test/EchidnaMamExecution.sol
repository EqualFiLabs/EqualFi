// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";

// Mock NFT to satisfy ownership and key derivation checks
contract MockPositionNFTMam {
    function ownerOf(uint256) external view returns (address) {
        return msg.sender;
    }
    function getPositionKey(uint256 tokenId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId));
    }
    function getPoolId(uint256) external pure returns (uint256) {
        return 1;
    }
}

contract EchidnaMamExecution is MamCurveExecutionFacet {
    MockERC20 internal tokenBase;
    MockERC20 internal tokenQuote;
    MockPositionNFTMam internal mockNft;
    
    uint256 internal constant PID_BASE = 1;
    uint256 internal constant PID_QUOTE = 2;
    uint256 internal constant MAKER_ID = 100;
    bytes32 internal makerKey;
    uint256 internal constant CURVE_ID = 1;
    
    constructor() {
        // Setup done in setup() for Echidna
    }

    function setup() public {
        tokenBase = new MockERC20("Base", "BASE", 18, 1_000_000 ether);
        tokenQuote = new MockERC20("Quote", "QUOTE", 18, 1_000_000 ether);
        mockNft = new MockPositionNFTMam();
        
        makerKey = keccak256(abi.encodePacked(MAKER_ID));

        // Initialize Pools
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        // Base Pool
        Types.PoolData storage pBase = s.pools[PID_BASE];
        pBase.initialized = true;
        pBase.underlying = address(tokenBase);
        pBase.userPrincipal[makerKey] = 1000 ether;
        pBase.totalDeposits = 1000 ether;
        pBase.trackedBalance = 1000 ether;
        pBase.feeIndex = LibFeeIndex.INDEX_SCALE;
        pBase.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        
        // Quote Pool
        Types.PoolData storage pQuote = s.pools[PID_QUOTE];
        pQuote.initialized = true;
        pQuote.underlying = address(tokenQuote);
        pQuote.feeIndex = LibFeeIndex.INDEX_SCALE;
        pQuote.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        
        // Setup Curve
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        ds.config.mamMakerShareBps = 8000; // 80% to maker
        ds.nextCurveId = CURVE_ID; // Ensure ID exists
        
        MamTypes.StoredCurve storage curve = ds.curves[CURVE_ID];
        curve.active = true;
        curve.remainingVolume = 500 ether; // 500 Base tokens for sale
        curve.endTime = uint40(block.timestamp + 1 days);
        
        LibDerivativeStorage.CurveData storage data = ds.curveData[CURVE_ID];
        data.makerPositionKey = makerKey;
        data.makerPositionId = MAKER_ID;
        data.poolIdA = PID_BASE;
        data.poolIdB = PID_QUOTE;
        
        LibDerivativeStorage.CurveImmutables storage imm = ds.curveImmutables[CURVE_ID];
        imm.tokenA = address(tokenBase);
        imm.tokenB = address(tokenQuote);
        imm.feeRateBps = 100; // 1%
        
        LibDerivativeStorage.CurvePricing storage pricing = ds.curvePricing[CURVE_ID];
        pricing.startPrice = 1e18; // 1:1
        pricing.endPrice = 0.5e18; // 0.5:1
        pricing.startTime = uint40(block.timestamp);
        pricing.duration = 1 days;
        
        ds.curveBaseIsA[CURVE_ID] = true; // Base is TokenA
        
        // Encumber the maker's base tokens
        LibEncumbrance.encumberIndex(makerKey, PID_BASE, CURVE_ID, 500 ether); 
    }
    
    // ========== ACTIONS ==========

    function action_swap(uint128 amountIn) public {
        if (amountIn == 0) return;
        
        // Self-funding the swap to bypass EOA approval issues
        // We act as the taker
        tokenQuote.mint(address(this), amountIn);
        tokenQuote.approve(address(this), amountIn);
        
        // Execute swap
        // We call via `this` to act as external caller (msg.sender = address(this))
        try this.executeCurveSwap(
            CURVE_ID,
            amountIn,
            0, // minOut
            uint64(block.timestamp + 1 days), // deadline
            address(this) // recipient
        ) {
            // Success
        } catch {
            // Expected reverts
        }
    }

    // ========== INVARIANTS ==========

    /// @notice Maker principal must match (initial - sold)
    function echidna_maker_base_balance() public view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage pBase = s.pools[PID_BASE];
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[CURVE_ID];
        
        uint256 sold = 500 ether - curve.remainingVolume;
        uint256 expectedPrincipal = 1000 ether - sold;
        
        return pBase.userPrincipal[makerKey] == expectedPrincipal;
    }
    
    /// @notice Maker encumbrance must match remaining volume
    function echidna_maker_encumbrance() public view returns (bool) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        MamTypes.StoredCurve storage curve = ds.curves[CURVE_ID];
        
        // Need to be careful with index ID. Is it CURVE_ID? 
        // In MamCurveCreationFacet: LibEncumbrance.encumberIndex(positionKey, poolId, curveId, amount)
        // So yes, curveId is the index.
        uint256 encumbered = LibEncumbrance.getIndexEncumberedForIndex(makerKey, PID_BASE, CURVE_ID);
        return encumbered == curve.remainingVolume;
    }
}

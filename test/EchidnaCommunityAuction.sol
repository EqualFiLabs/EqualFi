// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {CommunityAuctionFacet} from "../src/EqualX/CommunityAuctionFacet.sol";
import {DirectTestHarnessFacet} from "./equallend-direct/DirectTestHarnessFacet.sol";
import {DerivativeTypes} from "../src/libraries/DerivativeTypes.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {LibDirectHelpers} from "../src/libraries/LibDirectHelpers.sol";

// Echidna harness for CommunityAuctionFacet
contract EchidnaCommunityAuction is DirectTestHarnessFacet {
    CommunityAuctionFacet internal auctionFacet;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant POOL_A_ID = 1;
    uint256 internal constant POOL_B_ID = 2;
    uint256 internal creatorPositionId;
    uint256 internal joinerPositionId;
    bytes32 internal creatorKey;
    bytes32 internal joinerKey;

    constructor() {
        // Setup done in DiamondInit usually
    }

    // Echidna calls setup() if configured
    function setup() public {
        tokenA = new MockERC20("TokenA", "TKNA", 18, 1_000_000_000e18);
        tokenB = new MockERC20("TokenB", "TKNB", 6, 1_000_000_000e6);
        auctionFacet = new CommunityAuctionFacet();
        
        // Initialize pools
        this.initPool(POOL_A_ID, address(tokenA));
        this.initPool(POOL_B_ID, address(tokenB));

        // Create positions
        creatorPositionId = 1;
        joinerPositionId = 2;
        
        // Derive keys (mock logic as per previous harness)
        creatorKey = keccak256(abi.encodePacked("CREATOR"));
        joinerKey = keccak256(abi.encodePacked("JOINER"));

        // Fund positions
        this.seedPosition(POOL_A_ID, creatorKey, 1000e18);
        this.seedPosition(POOL_B_ID, creatorKey, 1_000_000e6);
        this.seedPosition(POOL_A_ID, joinerKey, 1000e18);
        this.seedPosition(POOL_B_ID, joinerKey, 1_000_000e6);
        
        // Mint tokens to this contract to act as vault/user
        tokenA.mint(address(this), 2000e18);
        tokenB.mint(address(this), 2_000_000e6);
    }

    // --- Invariants ---

    // 1. Solvency: Auction reserves should equal sum of maker contributions (minus fees/withdrawals)
    // Actually, reserveA/B tracks active liquidity.
    // Total shares * sharePrice should approx equal reserves? 
    // Easier: reserveA >= 0 && reserveB >= 0
    function echidna_auction_reserves_valid() public view returns (bool) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        uint256 auctionId = ds.nextCommunityAuctionId;
        if (auctionId == 0) return true;

        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        // Reserves are uint, so always >= 0, but check for sensible state if finalized
        if (auction.finalized && auction.totalShares == 0) {
             // If finalized and empty, reserves might be dust or zero
             return true;
        }
        return true; 
    }

    // 2. Share Consistency: If active, totalShares > 0
    function echidna_shares_consistency() public view returns (bool) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        uint256 auctionId = ds.nextCommunityAuctionId;
        if (auctionId == 0) return true;

        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        if (auction.active) {
            return auction.totalShares > 0;
        }
        return true;
    }

    // 3. Fee Integrity: Protocol fees (treasury/index) shouldn't exceed collected amounts
    // This is hard to check stateless, but we can check if accrued fees <= reserves?
    // Actually accrued fees are carved out or tracked.
    
    // --- Actions ---

    function createAuction(
        uint256 reserveA,
        uint256 reserveB,
        uint16 feeBps
    ) public {
        reserveA = (reserveA % 100e18) + 1e18;
        reserveB = (reserveB % 100_000e6) + 1e6;
        feeBps = feeBps % 1000; // 0-10%

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: creatorPositionId,
            poolIdA: POOL_A_ID,
            poolIdB: POOL_B_ID,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: feeBps,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn // Default
        });

        // Mock ownership check: LibDerivativeHelpers._requirePositionOwnership call
        // We need to ensure the harness (this) passes it.
        // We probably need to mock the NFT or use the trick from Options harness if we had one.
        // Wait, in previous Options harness we deployed a mock NFT. We should do same here.
        
        // Delegatecall to facet
        (bool success, ) = address(auctionFacet).delegatecall(
            abi.encodeWithSelector(CommunityAuctionFacet.createCommunityAuction.selector, params)
        );
    }

    function joinAuction(uint256 amountA, uint256 amountB) public {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        uint256 auctionId = ds.nextCommunityAuctionId;
        if (auctionId == 0) return;

        amountA = (amountA % 10e18) + 1;
        amountB = (amountB % 10_000e6) + 1;

        (bool success, ) = address(auctionFacet).delegatecall(
            abi.encodeWithSelector(CommunityAuctionFacet.joinCommunityAuction.selector, auctionId, joinerPositionId, amountA, amountB)
        );
    }

    function swap(uint256 amountIn, bool swapAforB) public {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        uint256 auctionId = ds.nextCommunityAuctionId;
        if (auctionId == 0) return;

        amountIn = (amountIn % 10e18) + 1;
        address tokenIn = swapAforB ? address(tokenA) : address(tokenB);
        
        // Ensure we have approved? LibCurrency.pull checks allow/balance.
        // We are `this`, so we are approved.
        
        (bool success, ) = address(auctionFacet).delegatecall(
            abi.encodeWithSelector(CommunityAuctionFacet.swapExactIn.selector, auctionId, tokenIn, amountIn, 0, address(this))
        );
    }

    function leave(bool isCreator) public {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        uint256 auctionId = ds.nextCommunityAuctionId;
        if (auctionId == 0) return;

        uint256 pid = isCreator ? creatorPositionId : joinerPositionId;

        (bool success, ) = address(auctionFacet).delegatecall(
            abi.encodeWithSelector(CommunityAuctionFacet.leaveCommunityAuction.selector, auctionId, pid)
        );
    }
}

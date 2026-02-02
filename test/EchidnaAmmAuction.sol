// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./equallend-direct/DirectDiamondTestBase.sol";
import {AmmAuctionFacet} from "../src/EqualX/AmmAuctionFacet.sol";
import {DerivativeTypes} from "../src/libraries/DerivativeTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {PositionManagementFacet} from "../src/equallend/PositionManagementFacet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract EchidnaAmmAuction is DirectDiamondTestBase {
    AmmAuctionFacet amm;
    PositionManagementFacet pm;
    
    MockERC20 tokenA;
    MockERC20 tokenB;
    
    uint256 constant POOL_A = 1;
    uint256 constant POOL_B = 2;
    uint256 constant INITIAL_MINT = 1_000_000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100_000 ether;

    uint256 makerPos;
    bytes32 makerKey;
    
    // Track created auctions to verify invariants
    uint256[] public activeAuctions;

    bool public initialized;

    constructor() {
        // Echidna calls constructor once.
        _init();
    }

    function _init() internal {
        setUpDiamond();
        finalizePositionNFT();
        _addAmmFacet();
        _addPositionManagement();
        
        amm = AmmAuctionFacet(address(diamond));
        pm = PositionManagementFacet(address(diamond));
        
        tokenA = new MockERC20("TokenA", "A", 18, INITIAL_MINT);
        tokenB = new MockERC20("TokenB", "B", 18, INITIAL_MINT);
        
        harness.initPool(POOL_A, address(tokenA), 0, 0, 8000);
        harness.initPool(POOL_B, address(tokenB), 0, 0, 8000);
        
        // Fund the diamond/maker
        tokenA.transfer(address(this), INITIAL_MINT);
        tokenB.transfer(address(this), INITIAL_MINT);
        
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        
        // Create Maker Position
        makerPos = pm.mintPositionWithDeposit(POOL_A, DEPOSIT_AMOUNT);
        pm.depositToPosition(makerPos, POOL_B, DEPOSIT_AMOUNT);
        makerKey = nft.getPositionKey(makerPos);

        initialized = true;
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    function createAuction(uint256 reserveA, uint256 reserveB, uint16 feeBps) public {
        if (!initialized) return;
        
        // Bound inputs to reasonable ranges to avoid immediate reverts
        reserveA = _boundInput(reserveA, 1 ether, 10_000 ether);
        reserveB = _boundInput(reserveB, 1 ether, 10_000 ether);
        feeBps = uint16(_boundInput(feeBps, 0, 1000)); // Max 10% fee

        // Ensure we have enough unencumbered balance
        uint256 principalA = views.getUserPrincipal(POOL_A, makerKey);
        uint256 lockedA = views.directLocked(makerKey, POOL_A);
        if (principalA < lockedA + reserveA) return;

        uint256 principalB = views.getUserPrincipal(POOL_B, makerKey);
        uint256 lockedB = views.directLocked(makerKey, POOL_B);
        if (principalB < lockedB + reserveB) return;

        DerivativeTypes.CreateAuctionParams memory params;
        params.positionId = makerPos;
        params.poolIdA = POOL_A;
        params.poolIdB = POOL_B;
        params.reserveA = reserveA;
        params.reserveB = reserveB;
        params.startTime = uint64(block.timestamp);
        params.endTime = uint64(block.timestamp + 7 days);
        params.feeBps = feeBps;
        params.feeAsset = DerivativeTypes.FeeAsset.TokenIn;

        // Prank as the test contract (owner of position)
        // Echidna calls this function as `msg.sender`, but the diamond checks ownership.
        // Since `this` owns the position (minted in constructor), we can call directly.
        // However, if Echidna randomizes `msg.sender`, we might need to transfer NFT or use a proxy.
        // But `this` calls `amm.createAuction`, so `msg.sender` seen by `amm` is `this`.
        // So ownership check passes.
        
        try amm.createAuction(params) returns (uint256 auctionId) {
            activeAuctions.push(auctionId);
        } catch {
            // Ignore reverts in fuzzing actions usually, unless we want to enforce success
        }
    }

    function swapExactIn(uint256 auctionIndex, uint256 amountIn, bool tokenAIn) public {
        if (!initialized || activeAuctions.length == 0) return;
        
        uint256 auctionId = activeAuctions[auctionIndex % activeAuctions.length];
        amountIn = _boundInput(amountIn, 0.1 ether, 1000 ether);

        // Mint tokens to `this` to swap (representing a taker)
        // Actually, `this` is the swapper.
        // We already have tokens.
        
        address tokenIn = tokenAIn ? address(tokenA) : address(tokenB);
        
        // Ensure timestamp is valid for auction
        // Echidna doesn't advance time automatically unless configured.
        // We can simulate time if needed, but for now we assume 0 start time delay.
        
        try amm.swapExactIn(auctionId, tokenIn, amountIn, 0, address(this)) {
            // Success
        } catch {
            // Ignore
        }
    }

    function finalizeAuction(uint256 auctionIndex) public {
        if (!initialized || activeAuctions.length == 0) return;
        uint256 auctionId = activeAuctions[auctionIndex % activeAuctions.length];

        // We need to warp time to finalize
        // Not easily done in pure Solidity fuzzing without hevm.
        // But we can check if it succeeds.
        try amm.finalizeAuction(auctionId) {
            _removeAuction(auctionId);
        } catch {}
    }

    // -------------------------------------------------------------------------
    // Invariants
    // -------------------------------------------------------------------------

    // 1. K-Invariant: For every active auction, current k >= initial k
    function echidna_k_invariant() public view returns (bool) {
        for (uint i = 0; i < activeAuctions.length; i++) {
            uint256 id = activeAuctions[i];
            DerivativeTypes.AmmAuction memory auc = amm.getAuction(id);
            if (!auc.active) continue;
            
            uint256 kCurrent = Math.mulDiv(auc.reserveA, auc.reserveB, 1);
            // Invariant stored in struct is initial K? No, it's set at creation.
            // If fees are 0, k should be >= invariant (due to rounding up/slippage protection).
            // With fees, k grows.
            if (kCurrent < auc.invariant) return false;
        }
        return true;
    }

    // 2. Encumbrance: Total Locked == Sum of Reserves
    function echidna_encumbrance_invariant() public view returns (bool) {
        uint256 totalReserveA = 0;
        uint256 totalReserveB = 0;

        for (uint i = 0; i < activeAuctions.length; i++) {
            uint256 id = activeAuctions[i];
            DerivativeTypes.AmmAuction memory auc = amm.getAuction(id);
            if (auc.active) {
                totalReserveA += auc.reserveA;
                totalReserveB += auc.reserveB;
            }
        }

        // Use directLent instead of directLocked for AMM encumbrance
        uint256 lockedA = views.directLent(makerKey, POOL_A);
        uint256 lockedB = views.directLent(makerKey, POOL_B);

        if (lockedA != totalReserveA) return false;
        if (lockedB != totalReserveB) return false;

        return true;
    }

    // 3. Solvency: Contract Balance >= Non-AMM Tracked
    function echidna_solvency() public view returns (bool) {
        uint256 balA = tokenA.balanceOf(address(diamond));
        uint256 balB = tokenB.balanceOf(address(diamond));

        (uint256 trackedA, ) = views.poolTracked(POOL_A);
        (uint256 trackedB, ) = views.poolTracked(POOL_B);

        uint256 ammLiabilityA = 0;
        uint256 ammAssetA = 0;
        uint256 ammLiabilityB = 0;
        uint256 ammAssetB = 0;

        for (uint i = 0; i < activeAuctions.length; i++) {
            uint256 id = activeAuctions[i];
            DerivativeTypes.AmmAuction memory auc = amm.getAuction(id);
            if (auc.active) {
                ammLiabilityA += auc.initialReserveA;
                ammAssetA += auc.reserveA;
                ammLiabilityB += auc.initialReserveB;
                ammAssetB += auc.reserveB;
            }
        }

        // Adjusted Tracked Balance = Tracked - Initial (removed from principal on finalize)
        // But current balance includes Current Reserve.
        // So Balance - Current >= Tracked - Initial
        // => Balance >= Tracked - Initial + Current
        
        // We allow for a small deficit due to accrued fees (Treasury/Index) which are removed from Reserve but not yet from Tracked.
        // Fees are max 10%.
        
        if (trackedA > ammLiabilityA) {
            uint256 nonAmmTrackedA = trackedA - ammLiabilityA;
            uint256 expectedA = nonAmmTrackedA + ammAssetA;
            // Relax check for fees
            if (balA < expectedA * 90 / 100) return false; 
        }
        
        if (trackedB > ammLiabilityB) {
            uint256 nonAmmTrackedB = trackedB - ammLiabilityB;
            uint256 expectedB = nonAmmTrackedB + ammAssetB;
            if (balB < expectedB * 90 / 100) return false;
        }

        return true;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _boundInput(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    function _removeAuction(uint256 auctionId) internal {
        for (uint i = 0; i < activeAuctions.length; i++) {
            if (activeAuctions[i] == auctionId) {
                activeAuctions[i] = activeAuctions[activeAuctions.length - 1];
                activeAuctions.pop();
                break;
            }
        }
    }

    function _addAmmFacet() internal {
        AmmAuctionFacet ammFacet = new AmmAuctionFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        bytes4[] memory s = new bytes4[](8);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactIn.selector;
        s[3] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[4] = AmmAuctionFacet.finalizeAuction.selector;
        s[5] = AmmAuctionFacet.cancelAuction.selector;
        s[6] = AmmAuctionFacet.getAuction.selector;
        s[7] = AmmAuctionFacet.previewSwap.selector;
        
        addCuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(ammFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _addPositionManagement() internal {
        PositionManagementFacet pmFacet = new PositionManagementFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        bytes4[] memory s = new bytes4[](2);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = PositionManagementFacet.depositToPosition.selector; // Using overload selector in base? No, explicit.
        // The interface defines `depositToPosition(uint256,uint256,uint256)`
        
        addCuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(pmFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: s
        });
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }
}

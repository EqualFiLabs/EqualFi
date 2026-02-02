// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./equallend-direct/DirectDiamondTestBase.sol";
import "../src/mocks/MockERC20.sol";
import "../src/libraries/DirectTypes.sol";

contract EchidnaDirectLending is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;

    uint256 internal lenderTokenId;
    uint256 internal borrowerTokenId;

    bool private _initialized;

    constructor() {
        setUpDiamond();
        
        tokenA = new MockERC20("Token A", "TKA", 18, 1000000e18);
        tokenB = new MockERC20("Token B", "TKB", 18, 1000000e18);

        harness.initPool(POOL_A, address(tokenA));
        harness.initPool(POOL_B, address(tokenB));

        // Create positions (associate with Pool A primarily, though they can use any pool)
        lenderTokenId = nft.mint(address(this), POOL_A);
        borrowerTokenId = nft.mint(address(this), POOL_B);
        
        // Seed tokens
        tokenA.mint(address(this), 1000000e18);
        tokenB.mint(address(this), 1000000e18);

        // Approve diamond
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);

        // Seed positions via harness
        harness.seedPosition(POOL_A, nft.getPositionKey(lenderTokenId), 10000e18); // Lender has Token A
        harness.seedPosition(POOL_B, nft.getPositionKey(borrowerTokenId), 10000e18); // Borrower has Token B
        
        // Also mint some to the diamond to back the seeded positions (so solvency checks pass)
        tokenA.transfer(address(diamond), 10000e18);
        tokenB.transfer(address(diamond), 10000e18);
        
        // Update total tracked in harness
        harness.setPoolTotals(POOL_A, 10000e18, 10000e18);
        harness.setPoolTotals(POOL_B, 10000e18, 10000e18);

        _initialized = true;
    }

    // Fuzzing Actions
    
    function postOffer(uint256 amount, uint16 aprBps, uint32 duration) public {
        if (!_initialized) return;
        
        // Constrain inputs
        amount = clamp(amount, 1e18, 1000e18);
        aprBps = uint16(clamp(aprBps, 0, 1000)); // 0-10%
        duration = uint32(clamp(duration, 1 days, 365 days));

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: POOL_A,
            collateralPoolId: POOL_B,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: amount,
            aprBps: aprBps,
            durationSeconds: duration,
            collateralLockAmount: amount,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: true
        });

        try offers.postOffer(params) {
            // Success
        } catch {
            // Ignore failures
        }
    }

    function cancelOffer(uint256 offerId) public {
        if (!_initialized) return;
        try offers.cancelOffer(offerId) {
            // Success
        } catch {
            // Ignore
        }
    }

    function createBorrowerOffer(uint256 amount, uint32 duration) public {
        if (!_initialized) return;
        
        amount = clamp(amount, 1e18, 1000e18);
        duration = uint32(clamp(duration, 1 days, 365 days));

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerTokenId,
            lenderPoolId: POOL_A,
            collateralPoolId: POOL_B,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: amount,
            aprBps: 0,
            durationSeconds: duration,
            collateralLockAmount: amount,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: true
        });

        try offers.postBorrowerOffer(params) {
            // Success
        } catch {
            // Ignore
        }
    }

    function acceptOffer(uint256 offerId) public {
        if (!_initialized) return;
        try agreements.acceptOffer(offerId, borrowerTokenId) {
            // Success
        } catch {
            // Ignore
        }
    }

    // Invariants
    
    function echidna_escrow_integrity() public view returns (bool) {
        // Total Escrow <= Total Principal (loose check)
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        uint256 escrow = views.offerEscrow(lenderKey, POOL_A);
        uint256 principal = views.getUserPrincipal(POOL_A, lenderKey);
        
        return escrow <= principal;
    }

    function echidna_solvency() public view returns (bool) {
        // Contract Balance >= Tracked Balance
        
        uint256 balanceA = tokenA.balanceOf(address(diamond));
        (uint256 trackedA,) = views.poolTracked(POOL_A);
        if (balanceA < trackedA) return false;

        uint256 balanceB = tokenB.balanceOf(address(diamond));
        (uint256 trackedB,) = views.poolTracked(POOL_B);
        if (balanceB < trackedB) return false;

        return true;
    }

    function echidna_encumbrance_validity() public view returns (bool) {
        // Locked Collateral <= User Principal
        
        // Lender check
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        uint256 principalA = views.getUserPrincipal(POOL_A, lenderKey);
        (uint256 lockedA, uint256 lentA,) = views.directBalances(lenderKey, POOL_A);
        
        // Encumbered (locked for offers + lent out) must be <= principal
        if (lockedA + lentA > principalA) return false;
        
        // Borrower check
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);
        uint256 principalB = views.getUserPrincipal(POOL_B, borrowerKey);
        (uint256 lockedB,, uint256 borrowedB) = views.directBalances(borrowerKey, POOL_B);
        
        // Locked collateral in pool B must be <= principal in pool B
        if (lockedB > principalB) return false;

        return true;
    }

    // Helpers
    function clamp(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max < min) return min;
        uint256 size = max - min + 1;
        return min + (x % size);
    }
}

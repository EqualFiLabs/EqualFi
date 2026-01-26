// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeFacet} from "../../src/core/FeeFacet.sol";
import {ActionFeeBoundsViolation} from "../../src/libraries/Errors.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibActionFees} from "../../src/libraries/LibActionFees.sol";
import {LibFeeTreasury} from "../../src/libraries/LibFeeTreasury.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Harness for testing FeeFacet with shared storage
contract FeeFacetHarness is FeeFacet {
    function initStorage(uint256 poolCount, uint256 indexCount, address _timelock) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        s.timelock = _timelock;
        s.poolCount = poolCount;
        
        // Initialize pools
        for (uint256 i = 0; i < poolCount; i++) {
            s.pools[i].underlying = address(new MockERC20("Mock Token", "MOCK", 18, 0));
            s.pools[i].initialized = true;
        }
        
        // Initialize indexes
        LibEqualIndex.EqualIndexStorage storage eqStore = LibEqualIndex.s();
        eqStore.indexCount = indexCount;
        for (uint256 i = 0; i < indexCount; i++) {
            eqStore.indexes[i].assets = new address[](1);
            eqStore.indexes[i].assets[0] = address(new MockERC20("Mock Token", "MOCK", 18, 0));
        }
    }
    
    // Helper functions for property tests
    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }
    
    function setTreasuryShare(uint16 shareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = shareBps;
        store.treasuryShareConfigured = true;
    }
    
    function setPoolTotalDeposits(uint256 pid, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
    }

    function setPoolTrackedBalance(uint256 pid, uint256 tracked) external {
        LibAppStorage.s().pools[pid].trackedBalance = tracked;
    }

    function getPoolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getPoolTotalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function getPoolYieldReserve(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function setPoolActiveCreditPrincipalTotal(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].activeCreditPrincipalTotal = amount;
    }
    
    function getPoolFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }
    
    function getFeeIndexRemainder() external view returns (uint256) {
        // Return remainder for pool 0 (default test pool)
        return LibAppStorage.s().pools[0].feeIndexRemainder;
    }
    
    function getFeeIndexRemainderForPool(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndexRemainder;
    }
    
    function getPoolUnderlying(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].underlying;
    }
    
    function chargePoolFee(uint256 pid, bytes32 action) external returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibActionFees.chargeFromPoolBalance(p, pid, action);
    }
}

/// @notice Property-based tests for FeeFacet
contract FeeFacetPropertyTest is Test {
    FeeFacetHarness internal feeFacet;
    address internal timelock;
    address internal owner;
    
    uint256 internal constant MAX_POOLS = 10;
    uint256 internal constant MAX_INDEXES = 10;
    
    // Action constants for testing
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");
    bytes32 internal constant ACTION_INDEX_MINT = keccak256("ACTION_INDEX_MINT");
    bytes32 internal constant ACTION_INDEX_BURN = keccak256("ACTION_INDEX_BURN");
    
    function setUp() public {
        feeFacet = new FeeFacetHarness();
        timelock = address(this);
        owner = address(this);
        feeFacet.initStorage(MAX_POOLS, MAX_INDEXES, timelock);
    }
    

    
    /// **Feature: unified-action-fees, Property 1: Fee configuration round-trip**
    /// For any pool or index, action type, fee amount, and enabled status,
    /// after setting the configuration, querying it should return the exact values that were set.
    function testProperty_FeeConfigurationRoundTrip_Pool(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 amount,
        bool enabled
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        amount = uint128(bound(amount, 0, type(uint128).max));
        
        // Set fee configuration (test contract is timelock)
        feeFacet.setPoolActionFee(pid, action, amount, enabled);
        
        // Query configuration
        (uint128 returnedAmount, bool returnedEnabled) = feeFacet.getPoolActionFee(pid, action);
        
        // Assert round-trip
        assertEq(returnedAmount, amount, "Amount mismatch");
        assertEq(returnedEnabled, enabled, "Enabled status mismatch");
    }
    
    /// **Feature: unified-action-fees, Property 1: Fee configuration round-trip**
    /// For any index, action type, fee amount, and enabled status,
    /// after setting the configuration, querying it should return the exact values that were set.
    function testProperty_FeeConfigurationRoundTrip_Index(
        uint8 indexIdRaw,
        uint8 actionSeed,
        uint128 amount,
        bool enabled
    ) public {
        // Bound inputs
        uint256 indexId = uint256(indexIdRaw) % MAX_INDEXES;
        bytes32 action = _getIndexActionFromSeed(actionSeed);
        amount = uint128(bound(amount, 0, type(uint128).max));
        
        // Set fee configuration (test contract is timelock)
        feeFacet.setIndexActionFee(indexId, action, amount, enabled);
        
        // Query configuration
        (uint128 returnedAmount, bool returnedEnabled) = feeFacet.getIndexActionFee(indexId, action);
        
        // Assert round-trip
        assertEq(returnedAmount, amount, "Amount mismatch");
        assertEq(returnedEnabled, enabled, "Enabled status mismatch");
    }
    
    /// **Feature: unified-action-fees, Property 5: Fee bounds enforcement**
    /// For any action fee being set, if fee bounds are configured and the fee amount is outside
    /// the minimum-maximum range, the transaction should revert; if bounds are not configured,
    /// any non-negative fee should be accepted.
    function testProperty_FeeBoundsEnforcement_Pool(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 minBound,
        uint128 maxBound,
        uint128 feeAmount
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        
        // Ensure min <= max
        if (minBound > maxBound) {
            (minBound, maxBound) = (maxBound, minBound);
        }
        
        // Set bounds (test contract is timelock)
        feeFacet.setActionFeeBounds(minBound, maxBound);
        
        // Try to set fee
        if (feeAmount < minBound || feeAmount > maxBound) {
            // Should revert
            vm.expectRevert(
                abi.encodeWithSelector(
                    ActionFeeBoundsViolation.selector,
                    feeAmount,
                    minBound,
                    maxBound
                )
            );
            feeFacet.setPoolActionFee(pid, action, feeAmount, true);
        } else {
            // Should succeed
            feeFacet.setPoolActionFee(pid, action, feeAmount, true);
            (uint128 returnedAmount,) = feeFacet.getPoolActionFee(pid, action);
            assertEq(returnedAmount, feeAmount, "Fee not set correctly");
        }
    }
    
    /// **Feature: unified-action-fees, Property 5: Fee bounds enforcement**
    /// For any index action fee being set, if fee bounds are configured and the fee amount is outside
    /// the minimum-maximum range, the transaction should revert.
    function testProperty_FeeBoundsEnforcement_Index(
        uint8 indexIdRaw,
        uint8 actionSeed,
        uint128 minBound,
        uint128 maxBound,
        uint128 feeAmount
    ) public {
        // Bound inputs
        uint256 indexId = uint256(indexIdRaw) % MAX_INDEXES;
        bytes32 action = _getIndexActionFromSeed(actionSeed);
        
        // Ensure min <= max
        if (minBound > maxBound) {
            (minBound, maxBound) = (maxBound, minBound);
        }
        
        // Set bounds (test contract is timelock)
        feeFacet.setActionFeeBounds(minBound, maxBound);
        
        // Try to set fee
        if (feeAmount < minBound || feeAmount > maxBound) {
            // Should revert
            vm.expectRevert(
                abi.encodeWithSelector(
                    ActionFeeBoundsViolation.selector,
                    feeAmount,
                    minBound,
                    maxBound
                )
            );
            feeFacet.setIndexActionFee(indexId, action, feeAmount, true);
        } else {
            // Should succeed
            feeFacet.setIndexActionFee(indexId, action, feeAmount, true);
            (uint128 returnedAmount,) = feeFacet.getIndexActionFee(indexId, action);
            assertEq(returnedAmount, feeAmount, "Fee not set correctly");
        }
    }
    
    /// **Feature: unified-action-fees, Property 8: Configuration change event emission**
    /// For any action fee configuration change (amount or enabled status), an event should be emitted
    /// containing the pool/index ID, action type, old values, and new values.
    function testProperty_ConfigurationChangeEventEmission_Pool(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 oldAmount,
        uint128 newAmount,
        bool oldEnabled,
        bool newEnabled
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        
        // Set initial configuration (test contract is timelock)
        feeFacet.setPoolActionFee(pid, action, oldAmount, oldEnabled);
        
        // Update configuration and check for event
        vm.expectEmit(true, true, false, true);
        emit FeeFacet.PoolActionFeeUpdated(pid, action, oldAmount, newAmount, newEnabled);
        feeFacet.setPoolActionFee(pid, action, newAmount, newEnabled);
    }
    
    /// **Feature: unified-action-fees, Property 8: Configuration change event emission**
    /// For any index action fee configuration change, an event should be emitted.
    function testProperty_ConfigurationChangeEventEmission_Index(
        uint8 indexIdRaw,
        uint8 actionSeed,
        uint128 oldAmount,
        uint128 newAmount,
        bool oldEnabled,
        bool newEnabled
    ) public {
        // Bound inputs
        uint256 indexId = uint256(indexIdRaw) % MAX_INDEXES;
        bytes32 action = _getIndexActionFromSeed(actionSeed);
        
        // Set initial configuration (test contract is timelock)
        feeFacet.setIndexActionFee(indexId, action, oldAmount, oldEnabled);
        
        // Update configuration and check for event
        vm.expectEmit(true, true, false, true);
        emit FeeFacet.IndexActionFeeUpdated(indexId, action, oldAmount, newAmount, newEnabled);
        feeFacet.setIndexActionFee(indexId, action, newAmount, newEnabled);
    }
    
    /// **Feature: unified-action-fees, Property 6: Preview accuracy without side effects**
    /// For any action and fee configuration, the preview function should return the exact fee amount
    /// that would be charged if the action were executed, without modifying any state.
    function testProperty_PreviewAccuracyWithoutSideEffects_Pool(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 amount,
        bool enabled
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        
        // Set fee configuration (test contract is timelock)
        feeFacet.setPoolActionFee(pid, action, amount, enabled);
        
        // Capture state before preview
        (uint128 amountBefore, bool enabledBefore) = feeFacet.getPoolActionFee(pid, action);
        
        // Preview fee
        uint256 previewedFee = feeFacet.previewActionFee(pid, action);
        
        // Capture state after preview
        (uint128 amountAfter, bool enabledAfter) = feeFacet.getPoolActionFee(pid, action);
        
        // Assert no state changes
        assertEq(amountBefore, amountAfter, "Amount changed after preview");
        assertEq(enabledBefore, enabledAfter, "Enabled status changed after preview");
        
        // Assert preview accuracy
        if (enabled) {
            assertEq(previewedFee, uint256(amount), "Preview amount incorrect");
        } else {
            assertEq(previewedFee, 0, "Preview should return 0 for disabled fee");
        }
    }
    
    /// **Feature: unified-action-fees, Property 6: Preview accuracy without side effects**
    /// For any index action and fee configuration, the preview function should return the exact fee amount.
    function testProperty_PreviewAccuracyWithoutSideEffects_Index(
        uint8 indexIdRaw,
        uint8 actionSeed,
        uint128 amount,
        bool enabled
    ) public {
        // Bound inputs
        uint256 indexId = uint256(indexIdRaw) % MAX_INDEXES;
        bytes32 action = _getIndexActionFromSeed(actionSeed);
        
        // Set fee configuration (test contract is timelock)
        feeFacet.setIndexActionFee(indexId, action, amount, enabled);
        
        // Capture state before preview
        (uint128 amountBefore, bool enabledBefore) = feeFacet.getIndexActionFee(indexId, action);
        
        // Preview fee
        uint256 previewedFee = feeFacet.previewIndexActionFee(indexId, action);
        
        // Capture state after preview
        (uint128 amountAfter, bool enabledAfter) = feeFacet.getIndexActionFee(indexId, action);
        
        // Assert no state changes
        assertEq(amountBefore, amountAfter, "Amount changed after preview");
        assertEq(enabledBefore, enabledAfter, "Enabled status changed after preview");
        
        // Assert preview accuracy
        if (enabled) {
            assertEq(previewedFee, uint256(amount), "Preview amount incorrect");
        } else {
            assertEq(previewedFee, 0, "Preview should return 0 for disabled fee");
        }
    }
    
    /// **Feature: unified-action-fees, Property 3: Universal fee distribution invariant**
    /// For any collected action fee from any operation, the sum of the treasury portion and the
    /// FeeIndex portion should equal the total fee amount collected, with no loss or creation of value.
    function testProperty_UniversalFeeDistributionInvariant(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 feeAmount,
        uint16 treasurySplitBps,
        uint256 depositorPrincipal
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        feeAmount = uint128(bound(feeAmount, 1, type(uint64).max)); // Keep reasonable to avoid overflow
        treasurySplitBps = uint16(bound(treasurySplitBps, 0, 10_000)); // 0-100%
        depositorPrincipal = bound(depositorPrincipal, 1 ether, 1_000_000 ether);
        
        // Setup: Configure treasury and treasury split
        address treasury = address(0xFEE);
        feeFacet.setTreasury(treasury);
        feeFacet.setTreasuryShare(treasurySplitBps);
        
        // Setup: Configure action fee
        feeFacet.setPoolActionFee(pid, action, feeAmount, true);
        
        // Setup: Seed pool with depositor principal for FeeIndex distribution
        feeFacet.setPoolTotalDeposits(pid, depositorPrincipal);
        // Ensure pool tracked balance can fund the treasury split
        feeFacet.setPoolTrackedBalance(pid, depositorPrincipal + feeAmount);
        
        // Setup: Give the contract enough tokens to pay the fee
        address underlying = feeFacet.getPoolUnderlying(pid);
        MockERC20(underlying).mint(address(feeFacet), feeAmount);
        
        // Capture balances before fee collection
        uint256 treasuryBalanceBefore = MockERC20(underlying).balanceOf(treasury);
        uint256 contractBalanceBefore = MockERC20(underlying).balanceOf(address(feeFacet));
        uint256 feeIndexBefore = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderBefore = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Charge fee from pool balance (simulates fee collection)
        feeFacet.chargePoolFee(pid, action);
        
        // Capture balances after fee collection
        uint256 treasuryBalanceAfter = MockERC20(underlying).balanceOf(treasury);
        uint256 contractBalanceAfter = MockERC20(underlying).balanceOf(address(feeFacet));
        uint256 feeIndexAfter = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderAfter = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Calculate actual distributions
        uint256 toTreasury = treasuryBalanceAfter - treasuryBalanceBefore;
        uint256 contractBalanceChange = contractBalanceBefore - contractBalanceAfter;
        
        // Calculate FeeIndex accrual in underlying token terms
        uint256 feeIndexDelta = feeIndexAfter - feeIndexBefore;
        uint256 toFeeIndex = (feeIndexDelta * depositorPrincipal) / 1e18;
        
        // Calculate remainder change (remainder is already scaled, so we need to unscale it)
        // The remainder represents scaled amounts that couldn't be evenly distributed
        uint256 remainderChange = remainderAfter > remainderBefore ? 
            (remainderAfter - remainderBefore) : 0;
        
        // Convert remainder to underlying token terms
        uint256 remainderInUnderlying = remainderChange / 1e18;
        
        // Property: Total distributed + remainder should equal fee amount (no loss or creation)
        // The remainder accounts for precision loss in the FeeIndex distribution
        // Allow for 1 wei rounding error due to division
        uint256 totalDistributed = toTreasury + toFeeIndex + remainderInUnderlying;
        assertApproxEqAbs(
            totalDistributed,
            feeAmount,
            1,
            "Fee distribution invariant violated: sum + remainder != total fee"
        );
        
        // Additional check: Contract balance should decrease by treasury portion only
        // (FeeIndex portion stays in contract for distribution to depositors)
        assertEq(
            contractBalanceChange,
            toTreasury,
            "Contract balance change should equal treasury portion"
        );
    }
    
    /// **Feature: unified-action-fees, Property 10: Treasury split calculation correctness**
    /// For any collected fee with a configured treasury split percentage, the treasury portion
    /// should equal the fee amount multiplied by the split percentage divided by 10000, and the
    /// FeeIndex portion should be the remainder.
    function testProperty_TreasurySplitCalculationCorrectness(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 feeAmount,
        uint16 treasurySplitBps,
        uint256 depositorPrincipal
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        feeAmount = uint128(bound(feeAmount, 1, type(uint64).max));
        treasurySplitBps = uint16(bound(treasurySplitBps, 0, 10_000)); // 0-100%
        depositorPrincipal = bound(depositorPrincipal, 1 ether, 1_000_000 ether);
        
        // Setup: Configure treasury and treasury split
        address treasury = address(0xFEE);
        feeFacet.setTreasury(treasury);
        feeFacet.setTreasuryShare(treasurySplitBps);
        
        // Setup: Configure action fee
        feeFacet.setPoolActionFee(pid, action, feeAmount, true);
        
        // Setup: Seed pool with depositor principal
        feeFacet.setPoolTotalDeposits(pid, depositorPrincipal);
        feeFacet.setPoolTrackedBalance(pid, depositorPrincipal + feeAmount);
        
        // Setup: Give the contract enough tokens
        address underlying = feeFacet.getPoolUnderlying(pid);
        MockERC20(underlying).mint(address(feeFacet), feeAmount);
        
        // Calculate expected split
        uint256 expectedToTreasury = (uint256(feeAmount) * treasurySplitBps) / 10_000;
        uint256 expectedToFeeIndexPortion = feeAmount - expectedToTreasury;
        
        // Capture balances before
        uint256 treasuryBalanceBefore = MockERC20(underlying).balanceOf(treasury);
        uint256 feeIndexBefore = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderBefore = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Charge fee
        feeFacet.chargePoolFee(pid, action);
        
        // Capture balances after
        uint256 treasuryBalanceAfter = MockERC20(underlying).balanceOf(treasury);
        uint256 feeIndexAfter = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderAfter = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Calculate actual distributions
        uint256 actualToTreasury = treasuryBalanceAfter - treasuryBalanceBefore;
        uint256 feeIndexDelta = feeIndexAfter - feeIndexBefore;
        uint256 actualToFeeIndex = (feeIndexDelta * depositorPrincipal) / 1e18;
        
        // Calculate remainder change (remainder is already scaled)
        uint256 remainderChange = remainderAfter > remainderBefore ? 
            (remainderAfter - remainderBefore) : 0;
        
        // Convert remainder to underlying token terms
        uint256 remainderInUnderlying = remainderChange / 1e18;
        
        // Property: Treasury portion should match expected calculation
        assertEq(
            actualToTreasury,
            expectedToTreasury,
            "Treasury portion incorrect"
        );
        
        // Property: FeeIndex portion + remainder should equal the expected FeeIndex portion
        // The remainder accounts for precision loss when distributing to depositors
        // Allow for 1 wei rounding error
        assertApproxEqAbs(
            actualToFeeIndex + remainderInUnderlying,
            expectedToFeeIndexPortion,
            1,
            "FeeIndex portion + remainder should equal expected FeeIndex portion"
        );
    }
    
    /// **Feature: unified-action-fees, Property 14: Zero treasury allocation when unconfigured**
    /// For any fee collection when the fee receiver is not configured (address zero), all fees
    /// should be allocated to the FeeIndex with zero sent to treasury.
    function testProperty_ZeroTreasuryAllocationWhenUnconfigured(
        uint8 pidRaw,
        uint8 actionSeed,
        uint128 feeAmount,
        uint256 depositorPrincipal
    ) public {
        // Bound inputs
        uint256 pid = uint256(pidRaw) % MAX_POOLS;
        bytes32 action = _getActionFromSeed(actionSeed);
        feeAmount = uint128(bound(feeAmount, 1, type(uint64).max));
        depositorPrincipal = bound(depositorPrincipal, 1 ether, 1_000_000 ether);
        
        // Setup: Ensure treasury is NOT configured (address zero)
        feeFacet.setTreasury(address(0));
        
        // Setup: Configure action fee
        feeFacet.setPoolActionFee(pid, action, feeAmount, true);
        
        // Setup: Seed pool with depositor principal
        feeFacet.setPoolTotalDeposits(pid, depositorPrincipal);
        
        // Setup: Give the contract enough tokens
        address underlying = feeFacet.getPoolUnderlying(pid);
        MockERC20(underlying).mint(address(feeFacet), feeAmount);
        feeFacet.setPoolTrackedBalance(pid, depositorPrincipal + feeAmount);
        uint256 requiredBacking = feeFacet.getPoolTotalDeposits(pid) + feeFacet.getPoolYieldReserve(pid) + feeAmount;
        if (feeFacet.getPoolTrackedBalance(pid) < requiredBacking) {
            feeFacet.setPoolTrackedBalance(pid, requiredBacking);
        }
        feeFacet.setPoolActiveCreditPrincipalTotal(pid, feeAmount);
        
        // Capture state before
        uint256 feeIndexBefore = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderBefore = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Charge fee
        feeFacet.chargePoolFee(pid, action);
        
        // Capture state after
        uint256 feeIndexAfter = feeFacet.getPoolFeeIndex(pid);
        uint256 remainderAfter = feeFacet.getFeeIndexRemainderForPool(pid);
        
        // Calculate FeeIndex accrual
        uint256 feeIndexDelta = feeIndexAfter - feeIndexBefore;
        uint256 toFeeIndex = (feeIndexDelta * depositorPrincipal) / 1e18;
        
        // Calculate remainder change (remainder is already scaled)
        uint256 remainderChange = remainderAfter > remainderBefore ? 
            (remainderAfter - remainderBefore) : 0;
        
        // Convert remainder to underlying token terms
        uint256 remainderInUnderlying = remainderChange / 1e18;
        
        // Property: All fees should go to FeeIndex + remainder when treasury is unconfigured
        // The remainder accounts for precision loss in the FeeIndex distribution
        // Allow for 1 wei rounding error
        assertApproxEqAbs(
            toFeeIndex + remainderInUnderlying,
            feeAmount,
            1,
            "All fees should go to FeeIndex + remainder when treasury unconfigured"
        );
        
        // Property: Treasury balance should remain zero (no transfer occurred)
        assertEq(
            MockERC20(underlying).balanceOf(address(0)),
            0,
            "Treasury (address zero) should have zero balance"
        );
    }

    // Helper functions
    
    function _getActionFromSeed(uint8 seed) internal pure returns (bytes32) {
        uint8 actionType = seed % 3;
        if (actionType == 0) return ACTION_BORROW;
        if (actionType == 1) return ACTION_REPAY;
        return ACTION_WITHDRAW;
    }
    
    function _getIndexActionFromSeed(uint8 seed) internal pure returns (bytes32) {
        if (seed % 2 == 0) return ACTION_INDEX_MINT;
        return ACTION_INDEX_BURN;
    }
}

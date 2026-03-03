// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibPerpsDomain} from "../../src/perps/LibPerpsDomain.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {Perps_IsolationViolation} from "../../src/perps/PerpsErrors.sol";

contract PerpsDomainHarness {
    function seedNonPerpsPool(uint256 poolId, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        pool.initialized = true;
        pool.trackedBalance = trackedBalance;
    }

    function trackedBalanceOf(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered)
        external
    {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function snapshot(uint256[] calldata poolIds) external view returns (uint256 nonPerpsTracked, uint256 isolatedTracked) {
        LibPerpsDomain.IsolationSnapshot memory snap = LibPerpsDomain.snapshotIsolation(poolIds);
        return (snap.nonPerpsTrackedTotal, snap.isolatedTrackedBalance);
    }

    function enforce(uint256[] calldata poolIds, uint256 beforeNonPerpsTracked, uint256 beforeIsolatedTracked, uint256 expectedCredit)
        external
        view
        returns (uint256)
    {
        LibPerpsDomain.IsolationSnapshot memory snap = LibPerpsDomain.IsolationSnapshot({
            nonPerpsTrackedTotal: beforeNonPerpsTracked,
            isolatedTrackedBalance: beforeIsolatedTracked
        });
        return LibPerpsDomain.enforceNonPerpsBackingInvariant(poolIds, snap, expectedCredit);
    }

    function totalTracked(uint256[] calldata poolIds) external view returns (uint256) {
        return LibPerpsDomain.totalNonPerpsTracked(poolIds);
    }

    function reserve(uint256 amount) external {
        LibPerpsDomain.reserveIsolatedBacking(amount);
    }

    function release(uint256 amount) external {
        LibPerpsDomain.releaseIsolatedBacking(amount);
    }

    function creditIsolated(uint256 amount) external {
        LibPerpsDomain.creditIsolatedTracked(amount);
    }

    function debitIsolated(uint256 amount) external {
        LibPerpsDomain.debitIsolatedTracked(amount);
    }

    function addLiabilities(uint256 amount) external {
        LibPerpsDomain.increaseLiabilities(amount);
    }

    function removeLiabilities(uint256 amount) external {
        LibPerpsDomain.decreaseLiabilities(amount);
    }

    function availableIsolatedBacking() external view returns (uint256) {
        return LibPerpsDomain.availableIsolatedBacking();
    }

    function enforceDomainSolvency(uint256 insuranceBalance, uint256 badDebtRecorded) external view {
        LibPerpsDomain.enforceDomainSolvency(insuranceBalance, badDebtRecorded);
    }

    function simulateExplicitOutboundCredit(uint256 poolId, uint256 amount) external {
        uint256 credited = LibPerpsDomain.routeOutboundFeeCredit(amount);
        LibAppStorage.s().pools[poolId].trackedBalance += credited;
    }

    function simulateUnexpectedNonPerpsDebit(uint256 poolId, uint256 amount) external {
        LibAppStorage.s().pools[poolId].trackedBalance -= amount;
    }
}

contract PerpsDomainPropertyTest is Test {
    PerpsDomainHarness internal h;

    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;

    function setUp() public {
        h = new PerpsDomainHarness();
    }

    function test_domainAccounting_reserveReleaseLiabilityAndAvailability() public {
        h.setDomainState(0, 0, 0);

        h.reserve(1_000);
        h.addLiabilities(250);
        h.creditIsolated(100);
        h.debitIsolated(50);
        h.removeLiabilities(100);
        h.release(200);

        LibPerpsStorage.PerpsDomainState memory ds = h.getDomainState();
        assertEq(ds.isolatedTrackedBalance, 850);
        assertEq(ds.isolatedLiabilities, 150);
        assertEq(ds.isolatedEncumbered, 800);
        assertEq(h.availableIsolatedBacking(), 700);
    }

    /// @dev Property 1: Non-Perps Backing Invariance
    /// Validates: Requirements 1.1, 1.2, 1.3, 20.1
    function testFuzz_property1_nonPerpsBackingInvariant_noDebitWhenPerpsOnlyMutates(
        uint96 poolATrackedSeed,
        uint96 poolBTrackedSeed,
        uint96 isolatedSeed,
        uint96 liabilitySeed,
        uint96 extraCreditSeed
    ) public {
        uint256 poolATracked = bound(uint256(poolATrackedSeed), 0, 1e24);
        uint256 poolBTracked = bound(uint256(poolBTrackedSeed), 0, 1e24);
        uint256 isolatedTracked = bound(uint256(isolatedSeed), 1, 1e24);
        uint256 liabilities = bound(uint256(liabilitySeed), 0, isolatedTracked);
        uint256 extraCredit = bound(uint256(extraCreditSeed), 0, 1e21);

        h.seedNonPerpsPool(POOL_A, poolATracked);
        h.seedNonPerpsPool(POOL_B, poolBTracked);
        h.setDomainState(isolatedTracked, liabilities, isolatedTracked);

        uint256[] memory poolIds = new uint256[](2);
        poolIds[0] = POOL_A;
        poolIds[1] = POOL_B;

        (uint256 beforeTracked, uint256 beforeIsolatedTracked) = h.snapshot(poolIds);

        // Perps-domain-only mutations: should not change non-perps tracked backing.
        h.creditIsolated(extraCredit);
        h.addLiabilities(extraCredit / 2);

        uint256 afterTracked = h.enforce(poolIds, beforeTracked, beforeIsolatedTracked, 0);
        assertEq(afterTracked, beforeTracked);
    }

    /// @dev Property 1: Non-Perps Backing Invariance
    /// Validates: Requirements 1.1, 1.2, 1.3, 20.1
    function testFuzz_property1_nonPerpsIncreaseMustEqualExplicitOutboundCredit(
        uint96 poolATrackedSeed,
        uint96 poolBTrackedSeed,
        uint96 isolatedTrackedSeed,
        uint96 creditSeed
    ) public {
        uint256 poolATracked = bound(uint256(poolATrackedSeed), 0, 1e24);
        uint256 poolBTracked = bound(uint256(poolBTrackedSeed), 0, 1e24);
        uint256 isolatedTracked = bound(uint256(isolatedTrackedSeed), 1, 1e24);
        uint256 credit = bound(uint256(creditSeed), 0, isolatedTracked);

        h.seedNonPerpsPool(POOL_A, poolATracked);
        h.seedNonPerpsPool(POOL_B, poolBTracked);
        h.setDomainState(isolatedTracked, 0, 0);

        uint256[] memory poolIds = new uint256[](2);
        poolIds[0] = POOL_A;
        poolIds[1] = POOL_B;

        (uint256 beforeTracked, uint256 beforeIsolatedTracked) = h.snapshot(poolIds);

        h.simulateExplicitOutboundCredit(POOL_A, credit);

        uint256 afterTracked = h.enforce(poolIds, beforeTracked, beforeIsolatedTracked, credit);
        assertEq(afterTracked, beforeTracked + credit);
    }

    /// @dev Property 1: Non-Perps Backing Invariance
    /// Validates: Requirements 1.1, 1.2, 1.3, 20.1
    function testFuzz_property1_nonPerpsDebitDetectedAndReverted(
        uint96 poolATrackedSeed,
        uint96 poolBTrackedSeed,
        uint96 debitSeed
    ) public {
        uint256 poolATracked = bound(uint256(poolATrackedSeed), 1, 1e24);
        uint256 poolBTracked = bound(uint256(poolBTrackedSeed), 0, 1e24);
        uint256 debit = bound(uint256(debitSeed), 1, poolATracked);

        h.seedNonPerpsPool(POOL_A, poolATracked);
        h.seedNonPerpsPool(POOL_B, poolBTracked);
        h.setDomainState(1_000, 0, 0);

        uint256[] memory poolIds = new uint256[](2);
        poolIds[0] = POOL_A;
        poolIds[1] = POOL_B;

        (uint256 beforeTracked, uint256 beforeIsolatedTracked) = h.snapshot(poolIds);

        h.simulateUnexpectedNonPerpsDebit(POOL_A, debit);

        vm.expectRevert(Perps_IsolationViolation.selector);
        h.enforce(poolIds, beforeTracked, beforeIsolatedTracked, 0);
    }

    function test_nonPerpsIncrease_mismatchedExpectedCreditReverts() public {
        h.seedNonPerpsPool(POOL_A, 1_000);
        h.seedNonPerpsPool(POOL_B, 500);
        h.setDomainState(1_000, 0, 0);

        uint256[] memory poolIds = new uint256[](2);
        poolIds[0] = POOL_A;
        poolIds[1] = POOL_B;

        (uint256 beforeTracked, uint256 beforeIsolatedTracked) = h.snapshot(poolIds);
        h.simulateExplicitOutboundCredit(POOL_A, 100);

        vm.expectRevert(Perps_IsolationViolation.selector);
        h.enforce(poolIds, beforeTracked, beforeIsolatedTracked, 99);
    }

    function test_domainSolvencyGuard_revertsWhenLiabilitiesExceedCoverage() public {
        h.setDomainState(100, 151, 0);

        vm.expectRevert(Perps_IsolationViolation.selector);
        h.enforceDomainSolvency(20, 30); // 100 + 20 + 30 < 151
    }
}

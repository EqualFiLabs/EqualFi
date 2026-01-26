// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LendingFacetHarness, LendingSnapshot} from "../root/LendingFacet.t.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceLendingHarness is LendingFacetHarness, MaintenanceFacet {
    bytes32 internal constant TEST_FEE_SOURCE = keccak256("TEST_FEE");
    bytes32 internal constant TEST_ACTIVE_SOURCE = keccak256("TEST_ACTIVE");

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setDefaultMaintenanceRate(uint16 rateBps) external {
        LibAppStorage.s().defaultMaintenanceRateBps = rateBps;
    }

    function setLastMaintenanceTimestamp(uint256 pid, uint64 ts) external {
        s().pools[pid].lastMaintenanceTimestamp = ts;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        LibFeeIndex.accrueWithSource(pid, amount, TEST_FEE_SOURCE);
    }

    function accrueActiveCredit(uint256 pid, uint256 amount) external {
        LibActiveCreditIndex.accrueWithSource(pid, amount, TEST_ACTIVE_SOURCE);
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function maintenanceIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].maintenanceIndex;
    }

    function activeCreditIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].activeCreditIndex;
    }

    function pendingMaintenance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].pendingMaintenance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }
}

contract MaintenanceStatefulHandler is Test {
    MaintenanceLendingHarness internal facet;
    MockERC20 internal token;
    uint256 internal pid;
    uint256 internal tokenId;
    bytes32 internal positionKey;
    address internal user;
    uint16 internal ltvBps;
    uint40[] internal termDurations;

    uint256 public lastFeeIndex;
    uint256 public lastMaintenanceIndex;
    uint256 public lastActiveCreditIndex;

    constructor(
        MaintenanceLendingHarness facet_,
        MockERC20 token_,
        uint256 pid_,
        uint256 tokenId_,
        bytes32 positionKey_,
        address user_,
        uint16 ltvBps_,
        uint40[] memory termDurations_
    ) {
        facet = facet_;
        token = token_;
        pid = pid_;
        tokenId = tokenId_;
        positionKey = positionKey_;
        user = user_;
        ltvBps = ltvBps_;
        for (uint256 i = 0; i < termDurations_.length; i++) {
            termDurations.push(termDurations_[i]);
        }
        _snapshotIndexes();
    }

    function openRolling(uint256 amountSeed) external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (snap.rollingLoan.active || snap.principal == 0 || snap.trackedBalance == 0) {
            return;
        }
        uint256 maxBorrow = (snap.principal * ltvBps) / 10_000;
        uint256 fixedDebt = _fixedPrincipalSum(snap);
        if (maxBorrow <= fixedDebt) {
            return;
        }
        uint256 capacity = maxBorrow - fixedDebt;
        uint256 amount = bound(amountSeed, 1, capacity);
        if (amount > snap.trackedBalance) {
            amount = snap.trackedBalance;
        }
        if (amount == 0) {
            return;
        }
        vm.prank(user);
        facet.openRollingFromPosition(tokenId, pid, amount);
    }

    function expandRolling(uint256 amountSeed) external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (!snap.rollingLoan.active || snap.trackedBalance == 0) {
            return;
        }
        uint256 maxBorrow = (snap.principal * ltvBps) / 10_000;
        uint256 fixedDebt = _fixedPrincipalSum(snap);
        uint256 currentDebt = snap.rollingLoan.principalRemaining + fixedDebt;
        if (maxBorrow <= currentDebt) {
            return;
        }
        uint256 remainingCapacity = maxBorrow - currentDebt;
        if (remainingCapacity == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, remainingCapacity);
        if (amount > snap.trackedBalance) {
            amount = snap.trackedBalance;
        }
        if (amount == 0) {
            return;
        }
        vm.prank(user);
        facet.expandRollingFromPosition(tokenId, pid, amount);
    }

    function makePayment(uint256 amountSeed) external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (!snap.rollingLoan.active) {
            return;
        }
        uint256 remaining = snap.rollingLoan.principalRemaining;
        if (remaining == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, remaining);
        if (token.balanceOf(user) < amount) {
            token.mint(user, amount);
        }
        vm.prank(user);
        facet.makePaymentFromPosition(tokenId, pid, amount);
    }

    function closeRolling() external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (!snap.rollingLoan.active) {
            return;
        }
        uint256 remaining = snap.rollingLoan.principalRemaining;
        if (token.balanceOf(user) < remaining) {
            token.mint(user, remaining);
        }
        vm.prank(user);
        facet.closeRollingCreditFromPosition(tokenId, pid);
    }

    function openFixed(uint256 amountSeed, uint256 termSeed) external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (snap.principal == 0 || snap.trackedBalance == 0) {
            return;
        }
        uint256 maxBorrow = (snap.principal * ltvBps) / 10_000;
        uint256 fixedDebt = _fixedPrincipalSum(snap);
        uint256 currentDebt = snap.rollingLoan.principalRemaining + fixedDebt;
        if (maxBorrow <= currentDebt) {
            return;
        }
        uint256 capacity = maxBorrow - currentDebt;
        uint256 amount = bound(amountSeed, 1, capacity);
        if (amount > snap.trackedBalance) {
            amount = snap.trackedBalance;
        }
        if (amount == 0) {
            return;
        }
        uint256 termIndex = termSeed % termDurations.length;
        vm.prank(user);
        facet.openFixedFromPosition(tokenId, pid, amount, termIndex);
    }

    function repayFixed(uint256 amountSeed, uint256 loanSeed) external {
        _snapshotIndexes();
        LendingSnapshot memory snap = facet.snapshot(pid, positionKey);
        if (snap.fixedLoanIds.length == 0) {
            return;
        }
        uint256 loanId = snap.fixedLoanIds[loanSeed % snap.fixedLoanIds.length];
        Types.FixedTermLoan memory loan = facet.getFixedLoan(pid, loanId);
        if (loan.principalRemaining == 0 || loan.closed) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, loan.principalRemaining);
        if (token.balanceOf(user) < amount) {
            token.mint(user, amount);
        }
        vm.prank(user);
        facet.repayFixedFromPosition(tokenId, pid, loanId, amount);
    }

    function bumpPrincipal(uint256 amountSeed) external {
        _snapshotIndexes();
        uint256 amount = bound(amountSeed, 1, 100 ether);
        facet.bumpPrincipal(pid, positionKey, amount);
    }

    function accrueFee(uint256 amountSeed) external {
        _snapshotIndexes();
        uint256 amount = bound(amountSeed, 1, 50 ether);
        facet.accrueFee(pid, amount);
    }

    function accrueActiveCredit(uint256 amountSeed) external {
        _snapshotIndexes();
        uint256 amount = bound(amountSeed, 1, 50 ether);
        facet.accrueActiveCredit(pid, amount);
    }

    function pokeMaintenance() external {
        _snapshotIndexes();
        facet.pokeMaintenance(pid);
    }

    function settleMaintenance() external {
        _snapshotIndexes();
        facet.settleMaintenance(pid);
    }

    function advanceTime(uint256 secondsSeed) external {
        _snapshotIndexes();
        uint256 delta = bound(secondsSeed, 1, 14 days);
        vm.warp(block.timestamp + delta);
    }

    function _fixedPrincipalSum(LendingSnapshot memory snap) internal view returns (uint256 total) {
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            Types.FixedTermLoan memory loan = facet.getFixedLoan(pid, snap.fixedLoanIds[i]);
            total += loan.principalRemaining;
        }
    }

    function _snapshotIndexes() internal {
        lastFeeIndex = facet.feeIndex(pid);
        lastMaintenanceIndex = facet.maintenanceIndex(pid);
        lastActiveCreditIndex = facet.activeCreditIndex(pid);
    }
}

contract MaintenanceStatefulInvariantTest is StdInvariant, Test {
    MaintenanceLendingHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal token;
    MaintenanceStatefulHandler internal handler;

    address internal user = address(0xB0B);
    uint256 internal tokenId;
    bytes32 internal positionKey;

    uint256 internal constant PID = 1;
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint16 internal constant LTV_BPS = 8000;
    uint40[] internal termDurations;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, 0);
        nft = new PositionNFT();
        facet = new MaintenanceLendingHarness();

        facet.configurePositionNFT(address(nft));
        facet.setFoundationReceiver(address(0xFEE));
        facet.setDefaultMaintenanceRate(100);
        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(PID, 7 days, 800);
        facet.addFixedConfig(PID, 30 days, 1000);
        facet.addFixedConfig(PID, 90 days, 1200);
        facet.setLastMaintenanceTimestamp(PID, uint64(block.timestamp));

        nft.setMinter(address(facet));
        tokenId = facet.mintFor(user, PID);
        positionKey = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, positionKey, PRINCIPAL);

        token.mint(user, 2_000 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);

        termDurations = new uint40[](3);
        termDurations[0] = 7 days;
        termDurations[1] = 30 days;
        termDurations[2] = 90 days;

        handler = new MaintenanceStatefulHandler(
            facet,
            token,
            PID,
            tokenId,
            positionKey,
            user,
            LTV_BPS,
            termDurations
        );
        targetContract(address(handler));
    }

    function invariant_feeIndexMonotonic() public {
        assertGe(facet.feeIndex(PID), handler.lastFeeIndex());
    }

    function invariant_maintenanceIndexMonotonic() public {
        assertGe(facet.maintenanceIndex(PID), handler.lastMaintenanceIndex());
    }

    function invariant_activeCreditIndexMonotonic() public {
        assertGe(facet.activeCreditIndex(PID), handler.lastActiveCreditIndex());
    }

    function invariant_backingCoversReserved() public {
        uint256 backing = facet.trackedBalance(PID) + facet.getActiveCreditPrincipalTotal(PID);
        uint256 reserved = facet.totalDeposits(PID) + facet.getYieldReserve(PID);
        assertGe(backing, reserved);
    }

    function invariant_activeCreditMatchesLoans() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        uint256 fixedDebt;
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, snap.fixedLoanIds[i]);
            fixedDebt += loan.principalRemaining;
        }
        uint256 activeCredit = facet.getActiveCreditPrincipalTotal(PID);
        assertEq(activeCredit, snap.rollingLoan.principalRemaining + fixedDebt);
    }
}

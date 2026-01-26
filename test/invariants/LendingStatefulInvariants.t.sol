// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingFacetHarness, LendingSnapshot} from "../root/LendingFacet.t.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract LendingStatefulHandler is Test {
    LendingFacetHarness internal facet;
    MockERC20 internal token;
    uint256 internal tokenId;
    bytes32 internal positionKey;
    address internal user;
    uint256 internal pid;
    uint16 internal ltvBps;
    uint40[] internal termDurations;

    mapping(uint256 => uint40) internal expectedExpiry;

    constructor(
        LendingFacetHarness facet_,
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
    }

    function openRolling(uint256 amountSeed) external {
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
        uint256 loanId = facet.openFixedFromPosition(tokenId, pid, amount, termIndex);
        expectedExpiry[loanId] = uint40(block.timestamp + termDurations[termIndex]);
    }

    function repayFixed(uint256 amountSeed, uint256 loanSeed) external {
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
        Types.FixedTermLoan memory updated = facet.getFixedLoan(pid, loanId);
        if (updated.principalRemaining == 0 || updated.closed) {
            delete expectedExpiry[loanId];
        }
    }

    function _fixedPrincipalSum(LendingSnapshot memory snap) internal view returns (uint256 total) {
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            Types.FixedTermLoan memory loan = facet.getFixedLoan(pid, snap.fixedLoanIds[i]);
            total += loan.principalRemaining;
        }
    }

    function getExpectedExpiry(uint256 loanId) external view returns (uint40) {
        return expectedExpiry[loanId];
    }
}

contract LendingStatefulInvariantTest is StdInvariant, Test {
    LendingFacetHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal token;
    LendingStatefulHandler internal handler;

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
        facet = new LendingFacetHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.setRollingMinPaymentBps(0);
        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, 0);
        termDurations = new uint40[](3);
        termDurations[0] = 7 days;
        termDurations[1] = 30 days;
        termDurations[2] = 90 days;
        facet.addFixedConfig(PID, termDurations[0], 300);
        facet.addFixedConfig(PID, termDurations[1], 500);
        facet.addFixedConfig(PID, termDurations[2], 800);

        tokenId = facet.mintFor(user, PID);
        positionKey = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, positionKey, PRINCIPAL);

        token.mint(user, PRINCIPAL * 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);

        handler = new LendingStatefulHandler(facet, token, PID, tokenId, positionKey, user, LTV_BPS, termDurations);
        targetContract(address(handler));
    }

    function invariant_activeCreditMatchesRolling() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        uint256 fixedDebt = _fixedPrincipalSum(snap);
        uint256 activeCredit = facet.getActiveCreditPrincipalTotal(PID);
        assertEq(activeCredit, snap.rollingLoan.principalRemaining + fixedDebt);
    }

    function invariant_poolConservation() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        uint256 fixedDebt = _fixedPrincipalSum(snap);
        assertEq(snap.trackedBalance + snap.rollingLoan.principalRemaining + fixedDebt, snap.totalDeposits);
    }

    function invariant_inactiveLoanHasZeroPrincipal() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        if (!snap.rollingLoan.active) {
            assertEq(snap.rollingLoan.principalRemaining, 0);
        }
    }

    function invariant_activeFixedCountMatchesIds() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        assertEq(snap.activeFixedLoanCount, snap.fixedLoanIds.length);
    }

    function invariant_fixedLoanIndexIntegrity() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            uint256 loanId = snap.fixedLoanIds[i];
            for (uint256 j = i + 1; j < snap.fixedLoanIds.length; j++) {
                assertTrue(loanId != snap.fixedLoanIds[j]);
            }
            Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
            assertEq(loan.borrower, positionKey);
            assertTrue(!loan.closed);
            assertGt(loan.principalRemaining, 0);
            assertEq(facet.getLoanIdIndex(PID, positionKey, loanId), i);
        }
    }

    function invariant_fixedLoanExpiryMatchesConfig() public {
        LendingSnapshot memory snap = facet.snapshot(PID, positionKey);
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            uint256 loanId = snap.fixedLoanIds[i];
            Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
            uint40 expected = handler.getExpectedExpiry(loanId);
            assertGt(expected, 0);
            assertEq(loan.expiry, expected);
            assertGe(loan.expiry, loan.openedAt);
        }
    }

    function _fixedPrincipalSum(LendingSnapshot memory snap) internal view returns (uint256 total) {
        for (uint256 i = 0; i < snap.fixedLoanIds.length; i++) {
            Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, snap.fixedLoanIds[i]);
            total += loan.principalRemaining;
        }
    }
}

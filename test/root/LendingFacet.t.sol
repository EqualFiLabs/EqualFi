// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LoanBelowMinimum, RollingError_MinPayment} from "../../src/libraries/Errors.sol";

struct LendingSnapshot {
    Types.RollingCreditLoan rollingLoan;
    uint256 trackedBalance;
    uint256 totalDeposits;
    uint256 principal;
    uint256 accruedYield;
    uint256 activeFixedLoanCount;
    uint256[] fixedLoanIds;
}

/// @notice Harness exposing setup helpers for LendingFacet
contract LendingFacetHarness is LendingFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function setRollingMinPaymentBps(uint16 minPaymentBps) external {
        LibAppStorage.s().rollingMinPaymentBps = minPaymentBps;
    }

    function initPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint16 ltvBps,
        uint16 rollingApy
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.minTopupAmount = minTopup;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.rollingApyBps = rollingApy;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }

    function addFixedConfig(uint256 pid, uint40 durationSecs, uint16 apyBps) external {
        s().pools[pid].poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function seedPosition(
        uint256 pid,
        bytes32 positionKey,
        uint256 principal
    ) external {
        Types.PoolData storage p = s().pools[pid];
        // Reset pool balances for deterministic tests
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
        MockERC20(p.underlying).mint(address(this), principal);
    }

    function bumpPrincipal(uint256 pid, bytes32 positionKey, uint256 amount) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] += amount;
        p.totalDeposits += amount;
        p.trackedBalance += amount;
        MockERC20(p.underlying).mint(address(this), amount);
    }

    function seedAccruedYield(uint256 pid, bytes32 positionKey, uint256 amount) external {
        Types.PoolData storage p = s().pools[pid];
        p.userAccruedYield[positionKey] = amount;
        p.yieldReserve = amount;
    }

    function getYieldReserve(uint256 pid) external view returns (uint256) {
        return s().pools[pid].yieldReserve;
    }

    function snapshot(uint256 pid, bytes32 positionKey) external view returns (LendingSnapshot memory snap) {
        Types.PoolData storage p = s().pools[pid];
        snap.rollingLoan = p.rollingLoans[positionKey];
        snap.trackedBalance = p.trackedBalance;
        snap.totalDeposits = p.totalDeposits;
        snap.principal = p.userPrincipal[positionKey];
        snap.accruedYield = p.userAccruedYield[positionKey];
        snap.activeFixedLoanCount = p.activeFixedLoanCount[positionKey];
        snap.fixedLoanIds = p.userFixedLoanIds[positionKey];
    }

    function getFixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return s().pools[pid].fixedTermLoans[loanId];
    }

    function getLoanIdIndex(uint256 pid, bytes32 positionKey, uint256 loanId) external view returns (uint256) {
        return s().pools[pid].loanIdToIndex[positionKey][loanId];
    }

    function getActiveCreditDebtState(uint256 pid, bytes32 positionKey)
        external
        view
        returns (Types.ActiveCreditState memory)
    {
        return s().pools[pid].userActiveCreditStateDebt[positionKey];
    }

    function getActiveCreditPrincipalTotal(uint256 pid) external view returns (uint256) {
        return s().pools[pid].activeCreditPrincipalTotal;
    }
}

/// @notice Unit tests for LendingFacet rolling/fixed lifecycle
/// @dev **Validates: Requirements 3.2, 7.1**
contract LendingFacetUnitTest is Test {
    PositionNFT public nft;
    LendingFacetHarness public facet;
    MockERC20 public token;

    address public user = address(0xA11CE);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    event AutoYieldRolledForBorrow(
        uint256 indexed tokenId,
        uint256 indexed poolId,
        bytes32 indexed positionKey,
        uint256 amount
    );

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        facet = new LendingFacetHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(PID, 30 days, 1000);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function _seedPosition(uint256 amount) internal returns (uint256 tokenId, bytes32 key) {
        vm.prank(user);
        tokenId = facet.mintFor(user, PID);
        key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, amount);
    }

    function test_openRolling_setsLoanStateAndTransfers() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.rollingLoan.principalRemaining, 20 ether, "principal remaining");
        assertEq(snap.trackedBalance, 80 ether, "tracked balance debited");
        assertTrue(snap.rollingLoan.active, "loan active");
    }

    function test_openRolling_setsActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 20 ether, "active credit principal");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 20 ether, "active credit total");
        assertGt(debtState.startTime, 0, "active credit start set");
    }

    function test_openRolling_autoRollsAccruedYield() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);
        facet.seedAccruedYield(PID, key, 5 ether);

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit AutoYieldRolledForBorrow(tokenId, PID, key, 5 ether);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.accruedYield, 0, "accrued yield cleared");
        assertEq(snap.principal, 105 ether, "principal includes rolled yield");
        assertEq(facet.getYieldReserve(PID), 0, "yield reserve reduced");
        assertEq(snap.trackedBalance, 85 ether, "tracked balance reflects roll + borrow");
    }

    function test_makePayment_reducesPrincipalOnly() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 payAmount = 5 ether;
        facet.makePaymentFromPosition(tokenId, PID, payAmount);
        vm.stopPrank();

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.rollingLoan.principalRemaining, 15 ether, "principal should decrease");
        assertEq(snap.trackedBalance, 100 ether - 20 ether + payAmount, "tracked balance updated");
    }

    function test_makePayment_reducesActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 payAmount = 5 ether;
        facet.makePaymentFromPosition(tokenId, PID, payAmount);
        vm.stopPrank();

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 15 ether, "active credit principal reduced");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 15 ether, "active credit total reduced");
    }

    function test_makePayment_revertsWhenBelowMinimumBps() public {
        (uint256 tokenId,) = _seedPosition(100 ether);
        facet.setRollingMinPaymentBps(500);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 payAmount = 0.5 ether;
        uint256 minPayment = (20 ether * 500) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(RollingError_MinPayment.selector, payAmount, minPayment)
        );
        facet.makePaymentFromPosition(tokenId, PID, payAmount);
        vm.stopPrank();
    }

    function test_expandRolling_increasesPrincipal() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 40 ether);
        facet.expandRollingFromPosition(tokenId, PID, 10 ether);
        vm.stopPrank();

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.rollingLoan.principalRemaining, 50 ether, "principal remaining after expand");
        assertEq(snap.trackedBalance, 150 ether, "tracked balance after expand");
    }

    function test_expandRolling_increasesActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 40 ether);
        facet.expandRollingFromPosition(tokenId, PID, 10 ether);
        vm.stopPrank();

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 50 ether, "active credit principal after expand");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 50 ether, "active credit total after expand");
    }

    function test_closeRolling_clearsLoan() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.warp(block.timestamp + 15 days);
        facet.closeRollingCreditFromPosition(tokenId, PID);
        vm.stopPrank();

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.rollingLoan.principalRemaining, 0, "principal cleared");
        assertFalse(snap.rollingLoan.active, "loan inactive");
    }

    function test_closeRolling_clearsActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.warp(block.timestamp + 15 days);
        facet.closeRollingCreditFromPosition(tokenId, PID);
        vm.stopPrank();

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 0, "active credit principal cleared");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 0, "active credit total cleared");
    }

    function test_openFixed_createsLoanAndKeepsPrincipalIntact() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.prank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 50 ether, 0);

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(loanId, 1, "loan id");
        assertEq(snap.fixedLoanIds.length, 1, "loan ids length");
        assertEq(snap.activeFixedLoanCount, 1, "active fixed count");
        assertEq(snap.principal, 200 ether, "principal unchanged");
        assertEq(snap.trackedBalance, 150 ether, "tracked balance debited for borrow");
    }

    function test_openFixed_setsActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.prank(user);
        facet.openFixedFromPosition(tokenId, PID, 50 ether, 0);

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 50 ether, "active credit principal");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 50 ether, "active credit total");
    }

    function test_repayFixed_reducesPrincipalRemaining() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.startPrank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 50 ether, 0);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 20 ether);
        vm.stopPrank();

        Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
        assertEq(loan.principalRemaining, 30 ether, "remaining principal");
        assertEq(facet.snapshot(PID, key).trackedBalance, 170 ether, "tracked balance after repay");
    }

    function test_repayFixed_reducesActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.startPrank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 50 ether, 0);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 20 ether);
        vm.stopPrank();

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 30 ether, "active credit principal reduced");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 30 ether, "active credit total reduced");
    }

    /// @dev Deterministic success-path for gas reporting: rolling lifecycle (open + payment).
    function test_gasRollingLifecycle() public {
        (uint256 tokenId,) = _seedPosition(200 ether);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, 50 ether);

        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        facet.makePaymentFromPosition(tokenId, PID, 10 ether);
    }

    /// @dev Deterministic success-path for gas reporting: fixed lifecycle (open + repay).
    function test_gasFixedLifecycle() public {
        (uint256 tokenId,) = _seedPosition(300 ether);

        vm.startPrank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 100 ether, 0);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 50 ether);
        vm.stopPrank();

        Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
        assertLe(loan.principalRemaining, 50 ether, "principal should reduce");
    }

    function test_openFixed_enforcesMinLoanAmount() public {
        // Reconfigure pool with higher minLoan
        facet.initPool(PID, address(token), 1, 50 ether, 1, LTV_BPS, 1000);
        facet.addFixedConfig(PID, 30 days, 1000);

        (uint256 tokenId,) = _seedPosition(200 ether);
        vm.expectRevert(abi.encodeWithSelector(LoanBelowMinimum.selector, 20 ether, 50 ether));
        vm.prank(user);
        facet.openFixedFromPosition(tokenId, PID, 20 ether, 0);
    }

    function test_repayFixed_supportsMultiplePartialRepaymentsAndCloses() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(300 ether);

        vm.startPrank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 90 ether, 0);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 30 ether);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 60 ether);
        vm.stopPrank();

        Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
        LendingSnapshot memory snap = facet.snapshot(PID, key);

        assertEq(loan.principalRemaining, 0, "principal fully repaid");
        assertTrue(loan.closed, "loan closed after full repay");
        assertEq(snap.activeFixedLoanCount, 0, "active fixed count cleared");
    }

    function test_openFixed_zeroInterestLeavesPrincipalIntact() public {
        uint256 pid2 = 2;
        facet.initPool(pid2, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(pid2, 30 days, 0); // zero APY

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, pid2);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(pid2, key, 100 ether);

        vm.prank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, pid2, 40 ether, 0);

        Types.FixedTermLoan memory loan = facet.getFixedLoan(pid2, loanId);
        LendingSnapshot memory snap = facet.snapshot(pid2, key);

        assertEq(loan.fullInterest, 0, "no interest accrued");
        assertEq(snap.principal, 100 ether, "principal unchanged when interest zero");
        assertEq(snap.trackedBalance, 60 ether, "tracked balance reduced by borrow");
    }

    function testProperty_FixedLoanZeroInterest(uint16 apyBps) public {
        uint256 pid2 = 2;
        facet.initPool(pid2, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(pid2, 30 days, apyBps);

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, pid2);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(pid2, key, 200 ether);

        vm.prank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, pid2, 40 ether, 0);

        Types.FixedTermLoan memory loan = facet.getFixedLoan(pid2, loanId);
        assertEq(loan.fullInterest, 0, "fixed fullInterest zero");
        assertFalse(loan.interestRealized, "fixed interestRealized false");
    }

    function testProperty_FixedLoanNoPrincipalDeduction(uint16 apyBps, uint256 depositAmount, uint256 borrowAmount)
        public
    {
        uint256 pid2 = 2;
        facet.initPool(pid2, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(pid2, 30 days, apyBps);

        depositAmount = bound(depositAmount, 50 ether, 500 ether);
        borrowAmount = bound(borrowAmount, 1 ether, depositAmount / 4);

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, pid2);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(pid2, key, depositAmount);

        vm.prank(user);
        facet.openFixedFromPosition(tokenId, pid2, borrowAmount, 0);

        LendingSnapshot memory snap = facet.snapshot(pid2, key);
        assertEq(snap.principal, depositAmount, "principal unchanged after fixed borrow");
    }

    function testProperty_RollingLoanZeroApy(uint16 rollingApy) public {
        uint256 pid2 = 2;
        facet.initPool(pid2, address(token), 1, 1, 1, LTV_BPS, rollingApy);

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, pid2);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(pid2, key, 100 ether);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, pid2, 20 ether);

        Types.RollingCreditLoan memory loan = facet.snapshot(pid2, key).rollingLoan;
        assertEq(loan.apyBps, 0, "rolling apy forced to zero");
    }

    function testProperty_PaymentPrincipalApplication(uint256 borrowAmount, uint256 paymentAmount) public {
        borrowAmount = bound(borrowAmount, 1 ether, 50 ether);
        paymentAmount = bound(paymentAmount, 1 ether, 100 ether);

        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, borrowAmount);
        facet.makePaymentFromPosition(tokenId, PID, paymentAmount);
        vm.stopPrank();

        uint256 expectedRemaining = borrowAmount > paymentAmount ? borrowAmount - paymentAmount : 0;
        Types.RollingCreditLoan memory loan = facet.snapshot(PID, key).rollingLoan;
        assertEq(loan.principalRemaining, expectedRemaining, "payment applied to principal");
    }

    function testProperty_PrincipalAtOpenRecorded_Rolling(
        uint256 depositAmount,
        uint256 borrowAmount
    ) public {
        depositAmount = bound(depositAmount, 10 ether, 1_000 ether);
        borrowAmount = bound(borrowAmount, 1 ether, (depositAmount * 7) / 10);

        (uint256 tokenId, bytes32 key) = _seedPosition(depositAmount);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, borrowAmount);

        Types.RollingCreditLoan memory loan = facet.snapshot(PID, key).rollingLoan;
        assertEq(loan.principalAtOpen, depositAmount, "rolling principalAtOpen");
    }

    function testProperty_PrincipalAtOpenRecorded_Fixed(
        uint256 depositAmount,
        uint256 borrowAmount
    ) public {
        depositAmount = bound(depositAmount, 10 ether, 1_000 ether);
        borrowAmount = bound(borrowAmount, 1 ether, depositAmount / 4);

        (uint256 tokenId, bytes32 key) = _seedPosition(depositAmount);

        vm.prank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, borrowAmount, 0);

        Types.FixedTermLoan memory loan = facet.getFixedLoan(PID, loanId);
        assertEq(loan.principalAtOpen, depositAmount, "fixed principalAtOpen");
        assertEq(loan.borrower, key, "fixed borrower");
    }

    function testProperty_SeparatePenaltyBasesPerLoan(
        uint256 depositAmount,
        uint256 extraDeposit
    ) public {
        uint256 pid2 = 2;
        facet.initPool(pid2, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(pid2, 30 days, 0);

        depositAmount = bound(depositAmount, 20 ether, 1_000 ether);
        extraDeposit = bound(extraDeposit, 1 ether, 500 ether);

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, pid2);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(pid2, key, depositAmount);

        uint256 maxDebt1 = (depositAmount * LTV_BPS) / 10_000;
        uint256 borrow1 = maxDebt1 / 2;
        vm.assume(borrow1 > 0);

        vm.startPrank(user);
        uint256 loanId1 = facet.openFixedFromPosition(tokenId, pid2, borrow1, 0);
        vm.stopPrank();

        facet.bumpPrincipal(pid2, key, extraDeposit);

        uint256 maxDebt2 = ((depositAmount + extraDeposit) * LTV_BPS) / 10_000;
        uint256 borrow2 = maxDebt2 > (borrow1 * 2) ? maxDebt2 - (borrow1 * 2) : 0;
        vm.assume(borrow2 > 0);

        vm.startPrank(user);
        uint256 loanId2 = facet.openFixedFromPosition(tokenId, pid2, borrow2, 0);
        vm.stopPrank();

        Types.FixedTermLoan memory loan1 = facet.getFixedLoan(pid2, loanId1);
        Types.FixedTermLoan memory loan2 = facet.getFixedLoan(pid2, loanId2);

        assertEq(loan1.principalAtOpen, depositAmount, "loan1 principalAtOpen");
        assertEq(loan2.principalAtOpen, depositAmount + extraDeposit, "loan2 principalAtOpen");
    }
}

/// @notice Property-style behavioral equivalence between two LendingFacet instances
/// @dev Exercises rolling and fixed flows and asserts mirrored state across identical facets
contract LendingFacetPropertyTest is Test {
    LendingFacetHarness public facet;
    LendingFacetHarness public mirror;
    PositionNFT public nft;
    PositionNFT public mirrorNft;
    MockERC20 public token;

    address public user = address(0xA11CE);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;
    uint16 constant ROLLING_APY = 1000;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        mirrorNft = new PositionNFT();
        facet = new LendingFacetHarness();
        mirror = new LendingFacetHarness();

        facet.configurePositionNFT(address(nft));
        mirror.configurePositionNFT(address(mirrorNft));
        nft.setMinter(address(facet));
        mirrorNft.setMinter(address(mirror));

        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, ROLLING_APY);
        mirror.initPool(PID, address(token), 1, 1, 1, LTV_BPS, ROLLING_APY);

        facet.addFixedConfig(PID, 30 days, 1200);
        mirror.addFixedConfig(PID, 30 days, 1200);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
        vm.prank(user);
        token.approve(address(mirror), type(uint256).max);
    }

    function testFuzz_BehavioralEquivalenceRollingAndFixed(
        uint256 depositAmount,
        uint256 rollingBorrow,
        uint256 paymentAmount,
        uint256 expandAmount,
        uint256 fixedBorrow,
        uint256 fixedRepay,
        bool closeRolling
    ) public {
        depositAmount = bound(depositAmount, 10 ether, 200_000 ether);
        rollingBorrow = bound(rollingBorrow, 0, (depositAmount * 7) / 10);
        expandAmount = bound(expandAmount, 0, depositAmount / 5);
        fixedBorrow = bound(fixedBorrow, 0, depositAmount / 4);

        vm.startPrank(user);
        uint256 tokenId = facet.mintFor(user, PID);
        uint256 mirrorTokenId = mirror.mintFor(user, PID);

        bytes32 key = nft.getPositionKey(tokenId);
        bytes32 mirrorKey = mirrorNft.getPositionKey(mirrorTokenId);

        facet.seedPosition(PID, key, depositAmount);
        mirror.seedPosition(PID, mirrorKey, depositAmount);

        if (rollingBorrow > 0) {
            try facet.openRollingFromPosition(tokenId, PID, rollingBorrow) {
                mirror.openRollingFromPosition(mirrorTokenId, PID, rollingBorrow);
            } catch (bytes memory err) {
                vm.expectRevert(err);
                mirror.openRollingFromPosition(mirrorTokenId, PID, rollingBorrow);
                return;
            }
        }

        vm.warp(block.timestamp + 7 days);

        LendingSnapshot memory snapBefore = facet.snapshot(PID, key);
        uint256 remaining = snapBefore.rollingLoan.principalRemaining;
        if (remaining > 0) {
            uint256 pay = remaining / 10;
            if (pay == 0) pay = 1;
            try facet.makePaymentFromPosition(tokenId, PID, pay) {
                mirror.makePaymentFromPosition(mirrorTokenId, PID, pay);
            } catch (bytes memory err) {
                vm.expectRevert(err);
                mirror.makePaymentFromPosition(mirrorTokenId, PID, pay);
                return;
            }
        }

        snapBefore = facet.snapshot(PID, key);
        if (snapBefore.rollingLoan.active && expandAmount > 0) {
            try facet.expandRollingFromPosition(tokenId, PID, expandAmount) {
                mirror.expandRollingFromPosition(mirrorTokenId, PID, expandAmount);
            } catch (bytes memory err) {
                vm.expectRevert(err);
                mirror.expandRollingFromPosition(mirrorTokenId, PID, expandAmount);
                return;
            }
        }

        snapBefore = facet.snapshot(PID, key);
        if (closeRolling && snapBefore.rollingLoan.active) {
            try facet.closeRollingCreditFromPosition(tokenId, PID) {
                mirror.closeRollingCreditFromPosition(mirrorTokenId, PID);
            } catch (bytes memory err) {
                vm.expectRevert(err);
                mirror.closeRollingCreditFromPosition(mirrorTokenId, PID);
                return;
            }
        }

        if (fixedBorrow > 0) {
            try facet.openFixedFromPosition(tokenId, PID, fixedBorrow, 0) {
                mirror.openFixedFromPosition(mirrorTokenId, PID, fixedBorrow, 0);
            } catch (bytes memory err) {
                vm.expectRevert(err);
                mirror.openFixedFromPosition(mirrorTokenId, PID, fixedBorrow, 0);
                return;
            }
        }

        vm.warp(block.timestamp + 15 days);
        if (fixedBorrow > 0) {
            fixedRepay = bound(fixedRepay, 0, fixedBorrow);
            if (fixedRepay > 0) {
                try facet.repayFixedFromPosition(tokenId, PID, 1, fixedRepay) {
                    mirror.repayFixedFromPosition(mirrorTokenId, PID, 1, fixedRepay);
                } catch (bytes memory err) {
                    vm.expectRevert(err);
                    mirror.repayFixedFromPosition(mirrorTokenId, PID, 1, fixedRepay);
                    return;
                }
            }
        }

        vm.stopPrank();

        LendingSnapshot memory snap = facet.snapshot(PID, key);
        LendingSnapshot memory mirrorSnap = mirror.snapshot(PID, mirrorKey);

        assertEq(snap.trackedBalance, mirrorSnap.trackedBalance, "tracked balance mismatch");
        assertEq(snap.totalDeposits, mirrorSnap.totalDeposits, "total deposits mismatch");
        assertEq(snap.principal, mirrorSnap.principal, "principal mismatch");
        assertEq(snap.accruedYield, mirrorSnap.accruedYield, "accrued yield mismatch");
        assertEq(snap.rollingLoan.principalRemaining, mirrorSnap.rollingLoan.principalRemaining, "rolling remaining");
        assertEq(snap.rollingLoan.active, mirrorSnap.rollingLoan.active, "rolling active");
        assertEq(snap.activeFixedLoanCount, mirrorSnap.activeFixedLoanCount, "fixed count");
        assertEq(snap.fixedLoanIds.length, mirrorSnap.fixedLoanIds.length, "fixed ids length");
    }
}

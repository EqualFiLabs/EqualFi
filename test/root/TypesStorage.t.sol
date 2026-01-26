// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/libraries/Types.sol";

contract TypesHarness {
    Types.PoolData internal pool;

    function setBasics(
        address underlying,
        bool isCapped,
        uint256 depositCap,
        uint16 ltvBps,
        uint16 rollingApyBps
    ) external {
        pool.underlying = underlying;
        pool.initialized = true;
        pool.poolConfig.isCapped = isCapped;
        pool.poolConfig.depositCap = depositCap;
        pool.poolConfig.depositorLTVBps = ltvBps;
        pool.poolConfig.rollingApyBps = rollingApyBps;
    }

    function getBasics()
        external
        view
        returns (
            address underlying,
            bool isCapped,
            uint256 depositCap,
            uint16 ltv,
            uint16 apy
        )
    {
        return (
            pool.underlying,
            pool.poolConfig.isCapped,
            pool.poolConfig.depositCap,
            pool.poolConfig.depositorLTVBps,
            pool.poolConfig.rollingApyBps
        );
    }

    function setLedger(bytes32 positionKey, uint256 principal, uint256 feeIndex, uint256 accrued, uint256 extCollat) external {
        pool.userPrincipal[positionKey] = principal;
        pool.userFeeIndex[positionKey] = feeIndex;
        pool.userAccruedYield[positionKey] = accrued;
        pool.externalCollateral[positionKey] = extCollat;
    }

    function ledgerOf(bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint256 feeIndex, uint256 accrued, uint256 extCollat)
    {
        return (
            pool.userPrincipal[positionKey],
            pool.userFeeIndex[positionKey],
            pool.userAccruedYield[positionKey],
            pool.externalCollateral[positionKey]
        );
    }

    function setMaintenanceState(uint16 rateBps, uint64 timestamp, uint256 pending) external {
        pool.poolConfig.maintenanceRateBps = rateBps;
        pool.lastMaintenanceTimestamp = timestamp;
        pool.pendingMaintenance = pending;
    }

    function maintenanceState() external view returns (uint16 rateBps, uint64 timestamp, uint256 pending) {
        return (pool.poolConfig.maintenanceRateBps, pool.lastMaintenanceTimestamp, pool.pendingMaintenance);
    }

    function pushFixedTermConfig(uint40 duration, uint16 apy, uint256 initiation) external {
        pool.poolConfig.fixedTermConfigs
            .push(
                Types.FixedTermConfig({durationSecs: duration, apyBps: apy})
            );
    }

    function fixedTermConfig(uint256 idx) external view returns (Types.FixedTermConfig memory) {
        return pool.poolConfig.fixedTermConfigs[idx];
    }

    function setFlashAntiSplit(bool enabled) external {
        pool.poolConfig.flashLoanAntiSplit = enabled;
    }

    function flashAntiSplit() external view returns (bool) {
        return pool.poolConfig.flashLoanAntiSplit;
    }

    function setFlashFeeBps(uint16 feeBps) external {
        pool.poolConfig.flashLoanFeeBps = feeBps;
    }

    function flashFeeBps() external view returns (uint16) {
        return pool.poolConfig.flashLoanFeeBps;
    }

    function setRollingLoan(bytes32 borrower, Types.RollingCreditLoan calldata loan) external {
        Types.RollingCreditLoan storage dst = pool.rollingLoans[borrower];
        dst.principal = loan.principal;
        dst.principalRemaining = loan.principalRemaining;
        dst.openedAt = loan.openedAt;
        dst.lastPaymentTimestamp = loan.lastPaymentTimestamp;
        dst.lastAccrualTs = loan.lastAccrualTs;
        dst.apyBps = loan.apyBps;
        dst.missedPayments = loan.missedPayments;
        dst.paymentIntervalSecs = loan.paymentIntervalSecs;
        dst.depositBacked = loan.depositBacked;
        dst.active = loan.active;
        dst.principalAtOpen = loan.principalAtOpen;
    }

    function rollingLoanOf(bytes32 borrower) external view returns (Types.RollingCreditLoan memory) {
        return pool.rollingLoans[borrower];
    }

    function updateRollingPrincipalRemaining(bytes32 borrower, uint256 principalRemaining) external {
        pool.rollingLoans[borrower].principalRemaining = principalRemaining;
    }

    function setFixedLoan(bytes32 borrower, uint256 id, Types.FixedTermLoan calldata loan) external {
        Types.FixedTermLoan storage dst = pool.fixedTermLoans[id];
        uint256 previousActive = dst.closed ? 0 : dst.principalRemaining;
        dst.principal = loan.principal;
        dst.principalRemaining = loan.principalRemaining;
        dst.fullInterest = loan.fullInterest;
        dst.openedAt = loan.openedAt;
        dst.expiry = loan.expiry;
        dst.apyBps = loan.apyBps;
        dst.borrower = borrower;
        dst.closed = loan.closed;
        dst.interestRealized = loan.interestRealized;
        dst.principalAtOpen = loan.principalAtOpen;
        uint256 newActive = loan.closed ? 0 : loan.principalRemaining;
        pool.activeFixedLoanCount[borrower] = loan.closed ? 0 : 1;
        if (newActive != previousActive) {
            if (newActive > previousActive) {
                pool.fixedTermPrincipalRemaining[borrower] += newActive - previousActive;
            } else {
                uint256 delta = previousActive - newActive;
                uint256 cached = pool.fixedTermPrincipalRemaining[borrower];
                pool.fixedTermPrincipalRemaining[borrower] = cached >= delta ? cached - delta : 0;
            }
        }
        pool.nextFixedLoanId = id + 1;
    }

    function fixedLoanOf(uint256 id) external view returns (Types.FixedTermLoan memory) {
        return pool.fixedTermLoans[id];
    }

    function updateFixedPrincipalRemaining(uint256 id, uint256 principalRemaining) external {
        pool.fixedTermLoans[id].principalRemaining = principalRemaining;
    }
}

contract TypesStorageTest is Test {
    TypesHarness internal harness;

    function setUp() public {
        harness = new TypesHarness();
    }

    function testPoolBasicsSetAndGet() public {
        harness.setBasics(address(0xA11CE), true, 1_000 ether, 7500, 900);
        (
            address underlying,
            bool isCapped,
            uint256 depositCap,
            uint16 ltv,
            uint16 apy
        ) = harness.getBasics();

        assertEq(underlying, address(0xA11CE));
        assertTrue(isCapped);
        assertEq(depositCap, 1_000 ether);
        assertEq(ltv, 7500);
        assertEq(apy, 900);
    }

    function testLedgerAndMaintenanceState() public {
        bytes32 user = bytes32(uint256(0xB0B));
        harness.setLedger(user, 1_000 ether, 1e18, 5 ether, 100 ether);
        (uint256 principal, uint256 feeIndex, uint256 accrued, uint256 extCollat) = harness.ledgerOf(user);
        assertEq(principal, 1_000 ether);
        assertEq(feeIndex, 1e18);
        assertEq(accrued, 5 ether);
        assertEq(extCollat, 100 ether);

        harness.setMaintenanceState(75, 67890, 2 ether);
        (uint16 rateBps, uint64 lastTimestamp, uint256 pending) = harness.maintenanceState();
        assertEq(rateBps, 75);
        assertEq(lastTimestamp, 67890);
        assertEq(pending, 2 ether);
    }

    function testFlashAndFixedConfig() public {
        harness.setFlashFeeBps(50);
        harness.pushFixedTermConfig(90 days, 1200, 0.1 ether);
        harness.setFlashAntiSplit(true);

        assertEq(harness.flashFeeBps(), 50);

        Types.FixedTermConfig memory cfg = harness.fixedTermConfig(0);
        assertEq(cfg.durationSecs, 90 days);
        assertEq(cfg.apyBps, 1200);

        assertTrue(harness.flashAntiSplit());
    }

    function testLoansStoreInStruct() public {
        uint40 baseTs = uint40(block.timestamp + 30 days);
        Types.RollingCreditLoan memory roll = Types.RollingCreditLoan({
            principal: 10_000 ether,
            principalRemaining: 8_000 ether,
            openedAt: baseTs,
            lastPaymentTimestamp: baseTs - 1 days,
            lastAccrualTs: baseTs - 2 days,
            apyBps: 900,
            missedPayments: 0,
            paymentIntervalSecs: 30 days,
            depositBacked: true,
            active: true,
            principalAtOpen: 12_000 ether
        });
        bytes32 rollingBorrower = bytes32(uint256(0xCAFE));
        harness.setRollingLoan(rollingBorrower, roll);
        Types.RollingCreditLoan memory storedRoll = harness.rollingLoanOf(rollingBorrower);
        assertEq(storedRoll.principalRemaining, 8_000 ether);
        assertTrue(storedRoll.active);
        assertTrue(storedRoll.depositBacked);
        assertEq(storedRoll.principalAtOpen, 12_000 ether);

        Types.FixedTermLoan memory fixedLoan = Types.FixedTermLoan({
            principal: 5_000 ether,
            principalRemaining: 4_000 ether,
            fullInterest: 750 ether,
            openedAt: baseTs - 10 days,
            expiry: baseTs + 20 days,
            apyBps: 800,
            borrower: bytes32(uint256(0xF00D)),
            closed: false,
            interestRealized: true,
            principalAtOpen: 6_000 ether
        });
        bytes32 fixedBorrower = bytes32(uint256(0xF00D));
        harness.setFixedLoan(fixedBorrower, 1, fixedLoan);
        Types.FixedTermLoan memory storedFixed = harness.fixedLoanOf(1);
        assertEq(storedFixed.principalRemaining, 4_000 ether);
        assertEq(storedFixed.apyBps, 800);
        assertEq(storedFixed.borrower, fixedBorrower);
        assertFalse(storedFixed.closed);
        assertEq(storedFixed.fullInterest, 750 ether);
        assertTrue(storedFixed.interestRealized);
        assertEq(storedFixed.principalAtOpen, 6_000 ether);
    }

    function testProperty_PrincipalAtOpenImmutable_Rolling(
        uint256 principalAtOpen,
        uint256 newPrincipalRemaining
    ) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        newPrincipalRemaining = bound(newPrincipalRemaining, 0, type(uint128).max);

        Types.RollingCreditLoan memory roll = Types.RollingCreditLoan({
            principal: 10 ether,
            principalRemaining: 10 ether,
            openedAt: uint40(block.timestamp),
            lastPaymentTimestamp: uint40(block.timestamp),
            lastAccrualTs: uint40(block.timestamp),
            apyBps: 900,
            missedPayments: 0,
            paymentIntervalSecs: 30 days,
            depositBacked: true,
            active: true,
            principalAtOpen: principalAtOpen
        });
        bytes32 borrower = bytes32(uint256(0xBEEF));
        harness.setRollingLoan(borrower, roll);

        harness.updateRollingPrincipalRemaining(borrower, newPrincipalRemaining);

        Types.RollingCreditLoan memory stored = harness.rollingLoanOf(borrower);
        assertEq(stored.principalAtOpen, principalAtOpen);
    }

    function testProperty_PrincipalAtOpenImmutable_Fixed(
        uint256 principalAtOpen,
        uint256 newPrincipalRemaining
    ) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        newPrincipalRemaining = bound(newPrincipalRemaining, 0, type(uint128).max);

        Types.FixedTermLoan memory fixedLoan = Types.FixedTermLoan({
            principal: 10 ether,
            principalRemaining: 10 ether,
            fullInterest: 1 ether,
            openedAt: uint40(block.timestamp),
            expiry: uint40(block.timestamp + 30 days),
            apyBps: 800,
            borrower: bytes32(uint256(0xF00D)),
            closed: false,
            interestRealized: true,
            principalAtOpen: principalAtOpen
        });
        uint256 loanId = 1;
        bytes32 borrower = bytes32(uint256(0xF00D));
        harness.setFixedLoan(borrower, loanId, fixedLoan);

        harness.updateFixedPrincipalRemaining(loanId, newPrincipalRemaining);

        Types.FixedTermLoan memory stored = harness.fixedLoanOf(loanId);
        assertEq(stored.principalAtOpen, principalAtOpen);
    }

    function testProperty_PrincipalAtOpenIndependentFromDeposits(
        uint256 principalAtOpen,
        uint256 newUserPrincipal
    ) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        newUserPrincipal = bound(newUserPrincipal, 0, type(uint128).max);
        bytes32 borrower = bytes32(uint256(0xD00D));

        Types.RollingCreditLoan memory roll = Types.RollingCreditLoan({
            principal: 10 ether,
            principalRemaining: 10 ether,
            openedAt: uint40(block.timestamp),
            lastPaymentTimestamp: uint40(block.timestamp),
            lastAccrualTs: uint40(block.timestamp),
            apyBps: 900,
            missedPayments: 0,
            paymentIntervalSecs: 30 days,
            depositBacked: true,
            active: true,
            principalAtOpen: principalAtOpen
        });
        harness.setRollingLoan(borrower, roll);

        Types.FixedTermLoan memory fixedLoan = Types.FixedTermLoan({
            principal: 10 ether,
            principalRemaining: 10 ether,
            fullInterest: 1 ether,
            openedAt: uint40(block.timestamp),
            expiry: uint40(block.timestamp + 30 days),
            apyBps: 800,
            borrower: borrower,
            closed: false,
            interestRealized: true,
            principalAtOpen: principalAtOpen
        });
        harness.setFixedLoan(borrower, 1, fixedLoan);

        harness.setLedger(borrower, newUserPrincipal, 0, 0, 0);

        Types.RollingCreditLoan memory storedRolling = harness.rollingLoanOf(borrower);
        Types.FixedTermLoan memory storedFixed = harness.fixedLoanOf(1);
        assertEq(storedRolling.principalAtOpen, principalAtOpen);
        assertEq(storedFixed.principalAtOpen, principalAtOpen);
    }
}

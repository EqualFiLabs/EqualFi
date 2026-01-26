// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibLoanHelpers} from "../../src/libraries/LibLoanHelpers.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Lightweight harness to surface shared utility libraries for testing
contract PositionSharedUtilityHarness {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint16 depositorLTVBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLTVBps;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function derivePositionKey(uint256 tokenId) external view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    function derivePoolId(uint256 tokenId) external view returns (uint256) {
        return LibPositionHelpers.derivePoolId(tokenId);
    }

    function assertOwnership(uint256 tokenId) external view {
        LibPositionHelpers.requireOwnership(tokenId);
    }

    function ensureMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) external returns (bool) {
        return LibPositionHelpers.ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }

    function setRollingLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 principalRemaining,
        bool active,
        uint32 paymentInterval,
        uint40 lastPaymentTimestamp,
        uint8 missedPayments
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = lastPaymentTimestamp;
        loan.lastAccrualTs = lastPaymentTimestamp;
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = paymentInterval;
        loan.depositBacked = true;
        loan.active = active;
    }

    function getRollingLoan(uint256 pid, bytes32 positionKey) external view returns (Types.RollingCreditLoan memory) {
        return LibAppStorage.s().pools[pid].rollingLoans[positionKey];
    }

    function setFixedLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 principalRemaining,
        bool closed
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        uint256 previousActivePrincipal = loan.closed ? 0 : loan.principalRemaining;
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.borrower = positionKey;
        loan.closed = closed;
        loan.apyBps = 1000;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = uint40(block.timestamp + 30 days);
        loan.interestRealized = true;
        if (p.userFixedLoanIds[positionKey].length == 0 || p.userFixedLoanIds[positionKey][p.userFixedLoanIds[positionKey].length - 1] != loanId) {
            LibLoanHelpers.addLoanIdWithIndex(p, pid, positionKey, loanId);
        }
        uint256 newActivePrincipal = closed ? 0 : principalRemaining;
        if (newActivePrincipal > 0 && previousActivePrincipal == 0) {
            p.activeFixedLoanCount[positionKey] += 1;
        } else if (newActivePrincipal == 0 && previousActivePrincipal > 0 && p.activeFixedLoanCount[positionKey] > 0) {
            p.activeFixedLoanCount[positionKey] -= 1;
        }

        if (newActivePrincipal != previousActivePrincipal) {
            if (newActivePrincipal > previousActivePrincipal) {
                p.fixedTermPrincipalRemaining[positionKey] += newActivePrincipal - previousActivePrincipal;
            } else {
                uint256 delta = previousActivePrincipal - newActivePrincipal;
                uint256 cached = p.fixedTermPrincipalRemaining[positionKey];
                p.fixedTermPrincipalRemaining[positionKey] = cached >= delta ? cached - delta : 0;
            }
        }
    }

    function calculateLoanDebts(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 rollingDebt, uint256 fixedDebt, uint256 totalLoanDebt)
    {
        return LibSolvencyChecks.calculateLoanDebts(LibAppStorage.s().pools[pid], positionKey);
    }

    function calculateTotalDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibSolvencyChecks.calculateTotalDebt(LibAppStorage.s().pools[pid], positionKey, pid);
    }

    function checkSolvency(uint256 pid, bytes32 positionKey, uint256 principal, uint256 debt)
        external
        view
        returns (bool)
    {
        return LibSolvencyChecks.checkSolvency(LibAppStorage.s().pools[pid], positionKey, principal, debt);
    }

    function setDirectExposure(
        bytes32 positionKey,
        uint256 pid,
        uint256 directLent,
        uint256 directBorrowed,
        uint256 directLocked
    ) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLent = directLent;
        ds.directBorrowedPrincipal[positionKey][pid] = directBorrowed;
        LibEncumbrance.position(positionKey, pid).directLocked = directLocked;
    }

    function calculateMissed(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        return LibLoanHelpers.calculateMissedEpochs(loan);
    }

    function calculateMissedView(Types.RollingCreditLoan memory loan) external view returns (uint256) {
        return LibLoanHelpers.calculateMissedEpochsView(loan);
    }

    function syncAndReturnMissed(uint256 pid, bytes32 positionKey) external returns (uint8) {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        LibLoanHelpers.syncMissedPayments(loan);
        return loan.missedPayments;
    }

    function accrueInterest(uint256 principal, uint16 apyBps, uint256 elapsed) external pure returns (uint256) {
        return LibLoanHelpers.calculateAccruedInterest(principal, apyBps, elapsed);
    }

    function thresholds() external view returns (uint8, uint8) {
        return LibLoanHelpers.delinquencyThresholds();
    }
}

/// @notice Property-based tests for shared utility consistency across helper libraries
/// @dev **Feature: position-nfts, Property 3: Shared utility consistency**
/// @dev **Validates: Requirements 6.3, 6.4, 6.5**
/// forge-config: default.fuzz.runs = 100
contract PositionNFTSharedUtilitiesPropertyTest is Test {
    PositionNFT public nft;
    PositionSharedUtilityHarness public harness;
    MockERC20 public token;

    address public user = address(0xAAAA);
    address public stranger = address(0xBEEF);

    uint256 constant POOL_ID = 1;
    uint16 constant LTV_BPS = 7500;

    function setUp() public {
        nft = new PositionNFT();
        harness = new PositionSharedUtilityHarness();
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(harness));
        harness.initPool(POOL_ID, address(token), LTV_BPS);
    }

    function testFuzz_PositionKeyAndOwnershipConsistency(uint256 pid) public {
        pid = bound(pid, 1, 5);
        harness.initPool(pid, address(token), LTV_BPS);

        vm.prank(user);
        uint256 tokenId = harness.mintFor(user, pid);

        bytes32 derivedKey = harness.derivePositionKey(tokenId);
        assertEq(derivedKey, nft.getPositionKey(tokenId), "position key mismatch");
        assertEq(harness.derivePoolId(tokenId), nft.getPoolId(tokenId), "pool id mismatch");

        vm.prank(user);
        harness.assertOwnership(tokenId);

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, tokenId));
        vm.prank(stranger);
        harness.assertOwnership(tokenId);
    }

    function testFuzz_DebtAggregationConsistency(
        uint256 rollingPrincipal,
        bool rollingActive,
        uint256 fixedPrincipal1,
        bool fixedClosed1,
        uint256 fixedPrincipal2,
        bool fixedClosed2,
        uint256 directLent,
        uint256 directBorrowed,
        uint256 directLocked
    ) public {
        rollingPrincipal = bound(rollingPrincipal, 0, 1_000_000 ether);
        fixedPrincipal1 = bound(fixedPrincipal1, 0, 1_000_000 ether);
        fixedPrincipal2 = bound(fixedPrincipal2, 0, 1_000_000 ether);
        directLent = bound(directLent, 0, 1_000_000 ether);
        directBorrowed = bound(directBorrowed, 0, 1_000_000 ether);
        directLocked = bound(directLocked, 0, 1_000_000 ether);

        vm.prank(user);
        uint256 tokenId = harness.mintFor(user, POOL_ID);
        bytes32 positionKey = nft.getPositionKey(tokenId);

        harness.setRollingLoan(
            POOL_ID,
            positionKey,
            rollingPrincipal,
            rollingActive,
            30 days,
            uint40(block.timestamp),
            0
        );

        harness.setFixedLoan(POOL_ID, positionKey, 1, fixedPrincipal1, fixedClosed1);
        harness.setFixedLoan(POOL_ID, positionKey, 2, fixedPrincipal2, fixedClosed2);
        harness.setDirectExposure(positionKey, POOL_ID, directLent, directBorrowed, directLocked);

        (uint256 rollingDebt, uint256 fixedDebt, uint256 totalLoanDebt) =
            harness.calculateLoanDebts(POOL_ID, positionKey);

        uint256 expectedRolling = rollingActive ? rollingPrincipal : 0;
        uint256 expectedFixed = (fixedClosed1 ? 0 : fixedPrincipal1) + (fixedClosed2 ? 0 : fixedPrincipal2);

        assertEq(rollingDebt, expectedRolling, "rolling debt inconsistent");
        assertEq(fixedDebt, expectedFixed, "fixed debt inconsistent");
        assertEq(totalLoanDebt, expectedRolling + expectedFixed, "loan debt aggregation inconsistent");

        uint256 totalDebt = harness.calculateTotalDebt(POOL_ID, positionKey);
        assertEq(totalDebt, totalLoanDebt + directBorrowed, "total debt missing direct exposure or loan components");

        uint256 principalBalance = expectedRolling + expectedFixed + directBorrowed + 1; // ensure positive collateral
        bool solvent = harness.checkSolvency(POOL_ID, positionKey, principalBalance, totalDebt);
        uint256 maxBorrowable = (principalBalance * LTV_BPS) / 10_000;
        bool expectedSolvent = totalDebt == 0 || totalDebt <= maxBorrowable;
        assertEq(solvent, expectedSolvent, "solvency helper inconsistent with calculation");
    }

    function testFuzz_MissedPaymentHelpersStayAligned(
        uint32 intervalSecs,
        uint40 lastPaymentTs,
        uint8 existingMissed
    ) public {
        intervalSecs = uint32(bound(intervalSecs, 1 days, 90 days));
        existingMissed = uint8(bound(existingMissed, 0, 3));

        vm.warp(10_000_000);

        vm.prank(user);
        uint256 tokenId = harness.mintFor(user, POOL_ID);
        bytes32 positionKey = nft.getPositionKey(tokenId);

        uint40 boundedLastPayment = uint40(bound(lastPaymentTs, 1, uint256(block.timestamp)));
        harness.setRollingLoan(
            POOL_ID,
            positionKey,
            1_000 ether,
            true,
            intervalSecs,
            boundedLastPayment,
            existingMissed
        );

        uint256 storageMissed = harness.calculateMissed(POOL_ID, positionKey);
        Types.RollingCreditLoan memory copy = harness.getRollingLoan(POOL_ID, positionKey);
        uint256 viewMissed = harness.calculateMissedView(copy);
        assertEq(storageMissed, viewMissed, "storage vs view missed epochs diverged");

        uint8 synced = harness.syncAndReturnMissed(POOL_ID, positionKey);
        uint256 capped = storageMissed > 3 ? 3 : storageMissed;
        uint8 expectedSynced = storageMissed > existingMissed ? uint8(capped) : existingMissed;
        assertEq(synced, expectedSynced, "sync missed payments not consistent");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

struct PenaltySnapshot {
    uint256 principal;
    uint256 trackedBalance;
    uint256 totalDeposits;
    uint256 userCount;
    Types.RollingCreditLoan rollingLoan;
    uint256[] fixedLoanIds;
    Types.FixedTermLoan fixedLoan;
    uint256 balanceTreasury;
    uint256 balanceEnforcer;
    uint256 feeIndex;
    uint256 activeCreditIndex;
}

/// @notice Harness exposing setup helpers for PenaltyFacet
contract PenaltyFacetHarness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(
        uint256 pid,
        address underlying,
        uint16 delinquencyEpochs,
        uint16 penaltyEpochs
    ) external {
        // Disable maintenance accrual in tests to avoid side effects
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = address(0);
        store.defaultMaintenanceRateBps = 0;
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.poolConfig.maintenanceRateBps = 0;
        // Initialize maintenance timestamp to prevent underflow in maintenance calculations
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        s().rollingDelinquencyEpochs = uint8(delinquencyEpochs);
        s().rollingPenaltyEpochs = uint8(penaltyEpochs);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMaintenanceConfig(address foundation, uint16 defaultRateBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = foundation;
        store.defaultMaintenanceRateBps = defaultRateBps;
    }

    function setLastMaintenanceTimestamp(uint256 pid, uint64 ts) external {
        s().pools[pid].lastMaintenanceTimestamp = ts;
    }

    function enforceMaintenance(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        
        // Manually set membership to avoid complex index calculations during testing
        LibPoolMembership.s().joined[positionKey][pid] = true;
        
        // Set basic pool state without complex calculations
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        // Provide ample tracked balance to cover penalty distributions and avoid underflow
        p.trackedBalance = principal + principal + principal + principal; // 4x principal
        p.userFeeIndex[positionKey] = LibFeeIndex.INDEX_SCALE; // Use constant instead of p.feeIndex
        p.userMaintenanceIndex[positionKey] = LibFeeIndex.INDEX_SCALE; // Use constant instead of p.maintenanceIndex
        p.userCount = 1;
        MockERC20(p.underlying).mint(address(this), principal);
    }

    function setDirectLockedPrincipal(uint256 pid, bytes32 positionKey, uint256 locked) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
    }

    function setDirectOfferEscrow(uint256 pid, bytes32 positionKey, uint256 escrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = escrowed;
    }

    function getDirectLockedPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getDirectOfferEscrow(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directOfferEscrow;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function seedRollingLoan(uint256 pid, bytes32 positionKey, uint256 principal, uint8 missedPayments) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.lastAccrualTs = uint40(block.timestamp);
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 1 days;
        loan.depositBacked = true;
        loan.active = true;
        loan.principalAtOpen = s().pools[pid].userPrincipal[positionKey];
    }

    function setRollingLoanFlags(uint256 pid, bytes32 positionKey, bool active, bool depositBacked) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.active = active;
        loan.depositBacked = depositBacked;
    }

    function setRollingPrincipalRemaining(uint256 pid, bytes32 positionKey, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principalRemaining = principalRemaining;
    }

    function setTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        s().pools[pid].trackedBalance = trackedBalance;
    }

    function seedFixedLoan(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 principal, uint40 expiry) external {
        Types.PoolData storage p = s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp - 1 days);
        loan.expiry = expiry;
        loan.apyBps = 1000;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;
        loan.principalAtOpen = p.userPrincipal[positionKey];
        p.activeFixedLoanCount[positionKey] += 1;
        // Store the index before pushing to avoid underflow
        uint256 index = p.userFixedLoanIds[positionKey].length;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = index;
    }

    function setFixedLoanBorrower(uint256 pid, uint256 loanId, bytes32 borrower) external {
        s().pools[pid].fixedTermLoans[loanId].borrower = borrower;
    }

    function setFixedLoanClosed(uint256 pid, uint256 loanId, bool closed) external {
        s().pools[pid].fixedTermLoans[loanId].closed = closed;
    }

    function setFixedLoanExpiry(uint256 pid, uint256 loanId, uint40 expiry) external {
        s().pools[pid].fixedTermLoans[loanId].expiry = expiry;
    }

    function setLoanIdToIndex(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 index) external {
        s().pools[pid].loanIdToIndex[positionKey][loanId] = index;
    }

    function seedFixedState(
        uint256 pid,
        address underlying,
        bytes32 borrower,
        uint256 principal,
        uint256 loanId,
        uint256 loanPrincipal
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.userPrincipal[borrower] = principal;
        p.userFeeIndex[borrower] = p.feeIndex;
        p.userMaintenanceIndex[borrower] = p.maintenanceIndex;
        p.totalDeposits = principal;
        p.trackedBalance = principal * 2;
        p.userCount = 1;
        LibPoolMembership._ensurePoolMembership(borrower, pid, true);

        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = loanPrincipal;
        loan.principalRemaining = loanPrincipal;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = uint40(block.timestamp);
        loan.apyBps = 0;
        loan.borrower = borrower;
        loan.closed = false;
        loan.interestRealized = true;
        loan.principalAtOpen = principal;

        p.userFixedLoanIds[borrower].push(loanId);
        p.loanIdToIndex[borrower][loanId] = 0;
        p.activeFixedLoanCount[borrower] = 1;

        MockERC20(underlying).mint(address(this), principal * 2);
    }

    function getPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].userPrincipal[key];
    }

    function getFixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return s().pools[pid].fixedTermLoans[loanId];
    }

    function snapshot(uint256 pid, bytes32 positionKey, address enforcer, address treasury)
        external
        view
        returns (PenaltySnapshot memory snap)
    {
        Types.PoolData storage p = s().pools[pid];
        snap.principal = p.userPrincipal[positionKey];
        snap.trackedBalance = p.trackedBalance;
        snap.totalDeposits = p.totalDeposits;
        snap.userCount = p.userCount;
        snap.rollingLoan = p.rollingLoans[positionKey];
        snap.fixedLoanIds = p.userFixedLoanIds[positionKey];
        if (snap.fixedLoanIds.length > 0) {
            snap.fixedLoan = p.fixedTermLoans[snap.fixedLoanIds[0]];
        }
        snap.balanceTreasury = IERC20(p.underlying).balanceOf(treasury);
        snap.balanceEnforcer = IERC20(p.underlying).balanceOf(enforcer);
        snap.feeIndex = p.feeIndex;
        snap.activeCreditIndex = p.activeCreditIndex;
    }

    function setActiveCreditBase(uint256 pid, uint256 base) external {
        Types.PoolData storage p = s().pools[pid];
        p.activeCreditPrincipalTotal = base;
        p.activeCreditMaturedTotal = base;
        if (p.activeCreditPendingStartHour == 0) {
            p.activeCreditPendingStartHour = uint64(block.timestamp / 1 hours) + 1;
        }
    }

    function setActiveCreditDebtState(
        uint256 pid,
        bytes32 positionKey,
        uint256 principal,
        uint40 startTime,
        uint256 snapshotIndex
    ) external {
        Types.ActiveCreditState storage debt = s().pools[pid].userActiveCreditStateDebt[positionKey];
        debt.principal = principal;
        debt.startTime = startTime;
        debt.indexSnapshot = snapshotIndex;
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

    function getActiveCreditIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].activeCreditIndex;
    }
}

contract DummyReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Unit tests for PenaltyFacet penalty flows
/// @dev **Validates: Requirements 3.3, 7.1**
contract PenaltyFacetUnitTest is Test {
    PositionNFT public nft;
    PenaltyFacetHarness public facet;
    DummyReceiver internal receiver;
    MockERC20 public token;

    address public user = address(0xA11CE);
    address public enforcer = address(0xBEEF);
    address public treasury = address(0x9999);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        facet = new PenaltyFacetHarness();
        receiver = new DummyReceiver();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 2, 3);

        facet.setTreasury(treasury);

        token.mint(address(facet), INITIAL_SUPPLY);

        token.transfer(user, 200_000 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function _mintAndSeed(uint256 principal) internal returns (uint256 tokenId, bytes32 key) {
        tokenId = facet.mintFor(address(receiver), PID);
        key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, principal);
    }

    function _splitPenalty(uint256 penaltyApplied, bool treasurySet)
        internal
        pure
        returns (uint256 enforcerShare, uint256 treasuryShare, uint256 activeShare, uint256 feeIndexShare)
    {
        enforcerShare = penaltyApplied / 10;
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        treasuryShare = treasurySet ? (protocolAmount * 2000) / 10_000 : 0;
        activeShare = 0;
        feeIndexShare = protocolAmount - treasuryShare - activeShare;
    }

    function test_penalizeRolling_distributesCollateral() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setActiveCreditBase(PID, 100 ether);

        uint256 enforcerBalBefore = token.balanceOf(enforcer);
        uint256 treasuryBalBefore = token.balanceOf(treasury);
        uint256 feeIndexBefore = facet.snapshot(PID, key, enforcer, treasury).feeIndex;
        uint256 activeIndexBefore = facet.getActiveCreditIndex(PID);

        facet.penalizePositionRolling(tokenId, PID, enforcer);

        uint256 penalty = (100 ether * 500) / 10_000;
        uint256 totalSeized = 50 ether + penalty;
        (uint256 enforcerShare, uint256 protocolShare, uint256 activeShare, uint256 feeIndexShare) =
            _splitPenalty(penalty, true);

        assertEq(token.balanceOf(enforcer) - enforcerBalBefore, enforcerShare, "enforcer share");
        assertEq(token.balanceOf(treasury) - treasuryBalBefore, protocolShare, "protocol share");
        assertEq(facet.snapshot(PID, key, enforcer, treasury).principal, 100 ether - totalSeized, "principal not reduced by seized total");

        // Fee index accrual uses remaining totalDeposits after seizure
        uint256 expectedFeeDelta = (feeIndexShare * LibFeeIndex.INDEX_SCALE) / facet.snapshot(PID, key, enforcer, treasury).totalDeposits;
        assertEq(facet.snapshot(PID, key, enforcer, treasury).feeIndex - feeIndexBefore, expectedFeeDelta, "fee index delta");

        // Active credit index accrual uses configured base
        uint256 expectedActiveDelta = (activeShare * LibActiveCreditIndex.INDEX_SCALE) / 100 ether;
        assertEq(facet.getActiveCreditIndex(PID) - activeIndexBefore, expectedActiveDelta, "active credit delta");
    }

    function test_penalizeRolling_clearsActiveCreditDebt() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setActiveCreditBase(PID, 50 ether);
        vm.warp(3 days);
        facet.setActiveCreditDebtState(PID, key, 50 ether, uint40(block.timestamp - 2 days), 0);

        facet.penalizePositionRolling(tokenId, PID, enforcer);

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 0, "active credit debt cleared");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 0, "active credit total cleared");
    }

    function test_penalizeRolling_respectsDirectEncumbrance() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setDirectLockedPrincipal(PID, key, 10 ether);
        facet.setDirectOfferEscrow(PID, key, 5 ether);

        facet.penalizePositionRolling(tokenId, PID, enforcer);

        uint256 penalty = (100 ether * 500) / 10_000;
        uint256 totalSeized = 50 ether + penalty;
        assertEq(facet.snapshot(PID, key, enforcer, treasury).principal, 100 ether - totalSeized);
        assertEq(facet.getDirectLockedPrincipal(PID, key), 10 ether, "locked unchanged");
        assertEq(facet.getDirectOfferEscrow(PID, key), 5 ether, "escrow unchanged");
    }

    function test_penalizeRolling_revertsWhenEncumberedExceedsPrincipal() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setDirectLockedPrincipal(PID, key, 80 ether);
        facet.setDirectOfferEscrow(PID, key, 20 ether);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 100 ether, 100 ether));
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeFixed_closesLoanAndClearsMembership() public {
        // Use seedFixedState helper to mirror working harness pattern
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 50 ether, 1, 20 ether);
        facet.setActiveCreditBase(PID, 100 ether);

        // Verify seeded state
        assertEq(facet.getPrincipal(PID, key), 50 ether, "principal seeded");
        assertFalse(facet.getFixedLoan(PID, 1).closed, "loan seeded closed");

        uint256 feeIndexBefore = facet.snapshot(PID, key, enforcer, treasury).feeIndex;
        uint256 activeIndexBefore = facet.getActiveCreditIndex(PID);
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        Types.FixedTermLoan memory loanAfter = facet.getFixedLoan(PID, 1);
        assertTrue(loanAfter.closed, "loan not closed");
        uint256 expectedPenalty = (50 ether * 500) / 10_000;
        uint256 totalSeized = 20 ether + expectedPenalty;
        assertEq(facet.getPrincipal(PID, key), 50 ether - totalSeized, "principal not reduced by seized total");
        assertEq(loanAfter.principalRemaining, 0, "principalRemaining not cleared");

        (uint256 enforcerShare, uint256 protocolShare, uint256 activeShare, uint256 feeIndexShare) =
            _splitPenalty(expectedPenalty, true);

        uint256 feeDelta =
            (feeIndexShare * LibFeeIndex.INDEX_SCALE) / facet.snapshot(PID, key, enforcer, treasury).totalDeposits;
        assertEq(facet.snapshot(PID, key, enforcer, treasury).feeIndex - feeIndexBefore, feeDelta, "fee delta fixed");

        uint256 activeDelta = (activeShare * LibActiveCreditIndex.INDEX_SCALE) / 100 ether;
        assertEq(facet.getActiveCreditIndex(PID) - activeIndexBefore, activeDelta, "active delta fixed");
    }

    function test_penalizeFixed_clearsActiveCreditDebt() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 20 ether);
        facet.setActiveCreditBase(PID, 20 ether);
        vm.warp(3 days);
        facet.setActiveCreditDebtState(PID, key, 20 ether, uint40(block.timestamp - 2 days), 0);

        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        Types.ActiveCreditState memory debtState = facet.getActiveCreditDebtState(PID, key);
        assertEq(debtState.principal, 0, "active credit debt cleared");
        assertEq(facet.getActiveCreditPrincipalTotal(PID), 0, "active credit total cleared");
    }

    function test_penalizeFixed_respectsDirectEncumbrance() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 20 ether);
        facet.setDirectLockedPrincipal(PID, key, 40 ether);
        facet.setDirectOfferEscrow(PID, key, 10 ether);

        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        uint256 penalty = (100 ether * 500) / 10_000;
        uint256 totalSeized = 20 ether + penalty;
        assertEq(facet.getPrincipal(PID, key), 100 ether - totalSeized, "principal reduced by seized total");
        assertEq(facet.getDirectLockedPrincipal(PID, key), 40 ether, "locked unchanged");
        assertEq(facet.getDirectOfferEscrow(PID, key), 10 ether, "escrow unchanged");
    }

    function test_penalizeFixed_revertsWhenEncumberedExceedsPrincipal() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 20 ether);
        facet.setDirectLockedPrincipal(PID, key, 90 ether);
        facet.setDirectOfferEscrow(PID, key, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 100 ether, 100 ether));
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeRolling_revertsWhenNotDelinquent() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(50 ether);
        facet.seedRollingLoan(PID, key, 10 ether, 1); // below penalty threshold

        vm.expectRevert("PositionNFT: not delinquent");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeRolling_revertsWhenNotActive() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setRollingLoanFlags(PID, key, false, true);

        vm.expectRevert("PositionNFT: loan not active");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeRolling_revertsWhenNoPrincipalRemaining() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setRollingPrincipalRemaining(PID, key, 0);

        vm.expectRevert("PositionNFT: no principal");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeRolling_revertsWhenNotDepositBacked() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setRollingLoanFlags(PID, key, true, false);

        vm.expectRevert("PositionNFT: only deposit-backed loans supported");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeRolling_revertsWhenTreasuryUnset() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        facet.setTreasury(address(0));
        uint256 treasuryBefore = token.balanceOf(treasury);
        facet.penalizePositionRolling(tokenId, PID, enforcer);
        assertEq(token.balanceOf(treasury), treasuryBefore, "treasury not paid when unset");
    }

    function test_penalizeRolling_revertsWhenTrackedBalanceBelowCollateral() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        uint256 penalty = (100 ether * 500) / 10_000;
        facet.setTrackedBalance(PID, penalty - 1);

        vm.expectRevert("PositionNFT: insufficient pool liquidity");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeRolling_revertsWhenContractBalanceBelowCollateral() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        facet.seedRollingLoan(PID, key, 50 ether, 5);
        // Keep trackedBalance high but force ERC20 balance lower than collateral.
        facet.setTrackedBalance(PID, 1000 ether);
        uint256 penalty = (100 ether * 500) / 10_000;
        deal(address(token), address(facet), penalty - 1);

        vm.expectRevert("PositionNFT: insufficient contract balance");
        facet.penalizePositionRolling(tokenId, PID, enforcer);
    }

    function test_penalizeFixed_revertsWhenNotBorrower() public {
        vm.warp(2 days);
        // Setup tokenId/key that will be used for penalty.
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, 100 ether);

        // Seed a fixed loan for a different borrower.
        uint256 otherTokenId = facet.mintFor(address(receiver), PID);
        bytes32 otherKey = nft.getPositionKey(otherTokenId);
        facet.seedFixedLoan(PID, otherKey, 1, 10 ether, uint40(block.timestamp)); // expired

        vm.expectRevert("PositionNFT: not borrower");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeFixed_revertsWhenLoanClosed() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);
        facet.setFixedLoanClosed(PID, 1, true);

        vm.expectRevert("PositionNFT: loan closed");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeFixed_revertsWhenNotExpired() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);
        facet.setFixedLoanExpiry(PID, 1, uint40(block.timestamp + 1 days));

        vm.expectRevert("PositionNFT: not expired");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeFixed_revertsWhenTreasuryUnset() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);
        facet.setTreasury(address(0));
        uint256 treasuryBefore = token.balanceOf(treasury);
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
        assertEq(token.balanceOf(treasury), treasuryBefore, "treasury not paid when unset");
    }

    function test_penalizeFixed_revertsWhenTrackedBalanceBelowCollateral() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);
        uint256 penalty = (100 ether * 500) / 10_000;
        facet.setTrackedBalance(PID, penalty - 1);

        vm.expectRevert("PositionNFT: insufficient pool liquidity");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeFixed_revertsWhenContractBalanceBelowCollateral() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);
        facet.setTrackedBalance(PID, 1000 ether);
        uint256 penalty = (100 ether * 500) / 10_000;
        deal(address(token), address(facet), penalty - 1);

        vm.expectRevert("PositionNFT: insufficient contract balance");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function test_penalizeFixed_revertsOnBadLoanIndexMapping() public {
        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, 100 ether, 1, 10 ether);

        // Tamper mapping so removeLoanIdByIndex fails.
        facet.setLoanIdToIndex(PID, key, 1, 1);

        vm.expectRevert("PositionNFT: bad loanIndex");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }
}

/// @notice Property-like fuzz tests for PenaltyFacet (new facet only)
/// @dev Validates penalty clears principals and loan state for both rolling and fixed paths
contract PenaltyFacetPropertyTest is Test {
    PositionNFT public nft;
    PenaltyFacetHarness public facet;
    DummyReceiver internal receiver;
    MockERC20 public token;

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    address public enforcer = address(0xBEEF);
    address public treasury = address(0x9999);

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        facet = new PenaltyFacetHarness();
        receiver = new DummyReceiver();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 2, 3);
        facet.setTreasury(treasury);

        token.mint(address(facet), INITIAL_SUPPLY);
    }

    function _splitPenalty(uint256 penaltyApplied, bool treasurySet)
        internal
        pure
        returns (uint256 enforcerShare, uint256 treasuryShare, uint256 activeShare, uint256 feeIndexShare)
    {
        enforcerShare = penaltyApplied / 10;
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        treasuryShare = treasurySet ? (protocolAmount * 2000) / 10_000 : 0;
        activeShare = 0;
        feeIndexShare = protocolAmount - treasuryShare - activeShare;
    }

    function testFuzz_LiquidateRollingClearsState(uint256 principal, uint256 loanPrincipal) public {
        principal = bound(principal, 2 ether, 500 ether);
        uint256 maxLoan = (principal * 95) / 100;
        if (maxLoan < 1 ether) {
            maxLoan = 1 ether;
        }
        loanPrincipal = bound(loanPrincipal, 1 ether, maxLoan);

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, principal);

        facet.seedRollingLoan(PID, key, loanPrincipal, 5);
        facet.penalizePositionRolling(tokenId, PID, enforcer);

        PenaltySnapshot memory snap = facet.snapshot(PID, key, enforcer, treasury);
        uint256 penalty = (principal * 500) / 10_000;
        uint256 penaltyApplied = penalty < loanPrincipal ? penalty : loanPrincipal;
        uint256 totalSeized = loanPrincipal + penaltyApplied;
        assertEq(snap.principal, principal - totalSeized, "rolling principal not reduced by seized total");
        assertFalse(snap.rollingLoan.active, "rolling still active");
        assertEq(snap.rollingLoan.principalRemaining, 0, "rolling remaining not cleared");
    }

    function test_maintenanceAccrualThenPenaltyKeepsTrackedBalanced(uint256 principal) public {
        principal = bound(principal, 50 ether, 200 ether);
        facet.setMaintenanceConfig(address(0xFEE1), 3650); // 10% annual for clearer deltas

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, principal);
        facet.seedRollingLoan(PID, key, principal / 2, 5);
        vm.warp(10 days);
        facet.setLastMaintenanceTimestamp(PID, uint64(block.timestamp - 5 days));

        PenaltySnapshot memory beforeSnap = facet.snapshot(PID, key, enforcer, treasury);
        uint256 foundationBefore = token.balanceOf(address(0xFEE1));
        uint256 enforcerBefore = token.balanceOf(enforcer);
        uint256 treasuryBefore = token.balanceOf(treasury);

        facet.enforceMaintenance(PID);

        uint256 foundationPaid = token.balanceOf(address(0xFEE1)) - foundationBefore;
        PenaltySnapshot memory midSnap = facet.snapshot(PID, key, enforcer, treasury);
        assertGt(foundationPaid, 0, "maintenance paid");
        assertLe(midSnap.trackedBalance, beforeSnap.trackedBalance, "tracked should not increase after maintenance");
        assertEq(beforeSnap.trackedBalance - midSnap.trackedBalance, foundationPaid, "tracked reflects maintenance");

        facet.penalizePositionRolling(tokenId, PID, enforcer);

        PenaltySnapshot memory afterSnap = facet.snapshot(PID, key, enforcer, treasury);
        uint256 enforcerGain = token.balanceOf(enforcer) - enforcerBefore;
        uint256 treasuryGain = token.balanceOf(treasury) - treasuryBefore;

        uint256 penalty = (midSnap.rollingLoan.principalAtOpen * 500) / 10_000;
        uint256 penaltyApplied = penalty < midSnap.rollingLoan.principalRemaining ? penalty : midSnap.rollingLoan.principalRemaining;
        (uint256 expectedEnforcer, uint256 expectedTreasury,,) = _splitPenalty(penaltyApplied, true);

        uint256 totalSeized = midSnap.rollingLoan.principalRemaining + penaltyApplied;
        assertEq(afterSnap.principal, midSnap.principal - totalSeized, "principal reduced by seized total");
        assertEq(enforcerGain, expectedEnforcer, "enforcer share");
        assertEq(treasuryGain, expectedTreasury, "treasury share");
        assertEq(midSnap.trackedBalance - afterSnap.trackedBalance, expectedEnforcer + expectedTreasury, "tracked after penalty");
    }

    function testProperty_RollingDefaultAccessControl(
        uint256 principal,
        uint256 loanPrincipal,
        uint8 missedPayments
    ) public {
        principal = bound(principal, 2 ether, 500 ether);
        uint256 maxLoan = (principal * 95) / 100;
        if (maxLoan < 1 ether) {
            maxLoan = 1 ether;
        }
        loanPrincipal = bound(loanPrincipal, 1 ether, maxLoan);
        missedPayments = uint8(bound(missedPayments, 0, 5));

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, principal);
        facet.seedRollingLoan(PID, key, loanPrincipal, missedPayments);

        if (missedPayments < 3) {
            vm.expectRevert("PositionNFT: not delinquent");
            facet.penalizePositionRolling(tokenId, PID, enforcer);
        } else {
            facet.penalizePositionRolling(tokenId, PID, enforcer);
        }
    }

    function testFuzz_LiquidateFixedClearsState(
        uint256 principal,
        uint256 loanPrincipal
    ) public {
        principal = bound(principal, 2 ether, 500 ether);
        uint256 maxLoan = (principal * 95) / 100;
        if (maxLoan < 1 ether) {
            maxLoan = 1 ether;
        }
        loanPrincipal = bound(loanPrincipal, 1 ether, maxLoan);

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, principal, 1, loanPrincipal);

        PenaltySnapshot memory beforeSnap = facet.snapshot(PID, key, enforcer, treasury);
        uint256 penalty = (principal * 500) / 10_000;
        uint256 penaltyApplied = penalty < loanPrincipal ? penalty : loanPrincipal;
        (uint256 expectedEnforcer, uint256 expectedTreasury,,) = _splitPenalty(penaltyApplied, true);
        uint256 totalSeized = loanPrincipal + penaltyApplied;

        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        PenaltySnapshot memory afterSnap = facet.snapshot(PID, key, enforcer, treasury);
        Types.FixedTermLoan memory loanAfter = facet.getFixedLoan(PID, 1);

        assertEq(afterSnap.principal, principal - totalSeized, "fixed principal not reduced by seized total");
        assertTrue(loanAfter.closed, "fixed loan not closed");
        assertEq(loanAfter.principalRemaining, 0, "principalRemaining not reduced");
        assertEq(afterSnap.totalDeposits, beforeSnap.totalDeposits - totalSeized, "totalDeposits not reduced");
        assertEq(afterSnap.balanceEnforcer - beforeSnap.balanceEnforcer, expectedEnforcer, "enforcer share");
        assertEq(afterSnap.balanceTreasury - beforeSnap.balanceTreasury, expectedTreasury, "treasury share");

        uint256 trackedExpected = beforeSnap.trackedBalance - (expectedEnforcer + expectedTreasury);
        assertEq(afterSnap.trackedBalance, trackedExpected, "tracked balance not updated");
    }

    function testProperty_FixedDefaultTiming(uint256 principal, uint256 loanPrincipal, uint40 delay) public {
        principal = bound(principal, 10 ether, 500 ether);
        uint256 maxLoan = (principal * 95) / 100;
        if (maxLoan < 1 ether) {
            maxLoan = 1 ether;
        }
        loanPrincipal = bound(loanPrincipal, 1 ether, maxLoan);
        delay = uint40(bound(delay, 1, 30 days));

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        uint40 expiry = uint40(block.timestamp + delay);
        facet.seedFixedState(PID, address(token), key, principal, 1, loanPrincipal);
        facet.setFixedLoanExpiry(PID, 1, expiry);

        vm.expectRevert("PositionNFT: not expired");
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        vm.warp(expiry + 1);
        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);
    }

    function testProperty_FixedDefaultNoClawback(uint256 principal, uint256 loanPrincipal) public {
        principal = bound(principal, 10 ether, 500 ether);
        uint256 maxLoan = (principal * 95) / 100;
        if (maxLoan < 1 ether) {
            maxLoan = 1 ether;
        }
        loanPrincipal = bound(loanPrincipal, 1 ether, maxLoan);

        uint256 tokenId = facet.mintFor(address(receiver), PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedFixedState(PID, address(token), key, principal, 1, loanPrincipal);

        uint256 penalty = (principal * 500) / 10_000;
        uint256 penaltyApplied = penalty < loanPrincipal ? penalty : loanPrincipal;
        uint256 totalSeized = loanPrincipal + penaltyApplied;

        facet.penalizePositionFixed(tokenId, PID, 1, enforcer);

        PenaltySnapshot memory afterSnap = facet.snapshot(PID, key, enforcer, treasury);
        assertEq(afterSnap.principal, principal - totalSeized, "principal reduced by seized total");
    }
}

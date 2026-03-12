// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";

contract LocalPenaltyMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PenaltyV1Harness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint256 delinquentEpochs, uint256 penaltyEpochs) external {
        if (delinquentEpochs > type(uint8).max) revert();
        if (penaltyEpochs > type(uint8).max) revert();
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.activeCreditIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = address(0);
        store.defaultMaintenanceRateBps = 0;
        store.rollingDelinquencyEpochs = uint8(delinquentEpochs);
        store.rollingPenaltyEpochs = uint8(penaltyEpochs);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setFeeSplits(uint256 treasuryShareBps, uint256 activeCreditShareBps) external {
        if (treasuryShareBps > type(uint16).max) revert();
        if (activeCreditShareBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryShareBps);
        store.activeCreditShareBps = uint16(activeCreditShareBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareConfigured = true;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        p.totalDeposits = principal;
        p.trackedBalance = principal * 4;
        p.userCount = 1;
        LocalPenaltyMockERC20V1(p.underlying).mint(address(this), principal * 4);
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function seedRollingLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 principalRemaining,
        uint256 missedPayments,
        uint256 principalAtOpen
    ) external {
        if (missedPayments > type(uint8).max) revert();
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.lastAccrualTs = uint40(block.timestamp);
        loan.apyBps = 1000;
        loan.missedPayments = uint8(missedPayments);
        loan.paymentIntervalSecs = 1 days;
        loan.depositBacked = true;
        loan.active = true;
        loan.principalAtOpen = principalAtOpen;
    }

    function seedFixedLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 principalRemaining,
        uint256 expiry,
        uint256 principalAtOpen
    ) external {
        if (expiry > type(uint40).max) revert();
        Types.PoolData storage p = s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp - 1 days);
        loan.expiry = uint40(expiry);
        loan.apyBps = 1000;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;
        loan.principalAtOpen = principalAtOpen;

        uint256 idx = p.userFixedLoanIds[positionKey].length;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = idx;
        p.activeFixedLoanCount[positionKey] += 1;
        p.fixedTermPrincipalRemaining[positionKey] += principalRemaining;
    }

    function setDirectLocked(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
    }

    function setTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        s().pools[pid].trackedBalance = trackedBalance;
    }

    function drainUnderlying(uint256 pid, address to, uint256 amount) external {
        LocalPenaltyMockERC20V1(s().pools[pid].underlying).transfer(to, amount);
    }

    function setRollingLoanActive(uint256 pid, bytes32 positionKey, bool active) external {
        s().pools[pid].rollingLoans[positionKey].active = active;
    }

    function setRollingLoanDepositBacked(uint256 pid, bytes32 positionKey, bool depositBacked) external {
        s().pools[pid].rollingLoans[positionKey].depositBacked = depositBacked;
    }

    function setRollingLoanMissedPayments(uint256 pid, bytes32 positionKey, uint256 missedPayments) external {
        if (missedPayments > type(uint8).max) revert();
        s().pools[pid].rollingLoans[positionKey].missedPayments = uint8(missedPayments);
    }

    function setRollingLoanLastPaymentTimestamp(uint256 pid, bytes32 positionKey, uint256 lastPaymentTimestamp) external {
        if (lastPaymentTimestamp > type(uint40).max) revert();
        s().pools[pid].rollingLoans[positionKey].lastPaymentTimestamp = uint40(lastPaymentTimestamp);
    }

    function setFixedLoanClosed(uint256 pid, uint256 loanId, bool closed) external {
        s().pools[pid].fixedTermLoans[loanId].closed = closed;
    }

    function setFixedLoanBorrower(uint256 pid, uint256 loanId, bytes32 borrower) external {
        s().pools[pid].fixedTermLoans[loanId].borrower = borrower;
    }

    function seedDebtState(uint256 pid, bytes32 positionKey, uint256 principal, uint256 startTime, uint256 indexSnapshot)
        external
    {
        if (startTime > type(uint40).max) revert();
        Types.ActiveCreditState storage debt = s().pools[pid].userActiveCreditStateDebt[positionKey];
        debt.principal = principal;
        debt.startTime = uint40(startTime);
        debt.indexSnapshot = indexSnapshot;
    }

    function setActiveCreditPrincipalTotal(uint256 pid, uint256 total) external {
        s().pools[pid].activeCreditPrincipalTotal = total;
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function getPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return s().pools[pid].userPrincipal[positionKey];
    }

    function getRollingLoan(uint256 pid, bytes32 positionKey) external view returns (Types.RollingCreditLoan memory) {
        return s().pools[pid].rollingLoans[positionKey];
    }

    function getFixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return s().pools[pid].fixedTermLoans[loanId];
    }

    function getFixedLoanIds(uint256 pid, bytes32 positionKey) external view returns (uint256[] memory) {
        return s().pools[pid].userFixedLoanIds[positionKey];
    }

    function getLoanIdIndex(uint256 pid, bytes32 positionKey, uint256 loanId) external view returns (uint256) {
        return s().pools[pid].loanIdToIndex[positionKey][loanId];
    }

    function getActiveFixedLoanCount(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return s().pools[pid].activeFixedLoanCount[positionKey];
    }

    function getFixedTermPrincipalRemaining(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return s().pools[pid].fixedTermPrincipalRemaining[positionKey];
    }

    function getDebtState(uint256 pid, bytes32 positionKey) external view returns (Types.ActiveCreditState memory) {
        return s().pools[pid].userActiveCreditStateDebt[positionKey];
    }

    function getActiveCreditPrincipalTotal(uint256 pid) external view returns (uint256) {
        return s().pools[pid].activeCreditPrincipalTotal;
    }
}

contract PenaltyFacetV1Test is Test {
    PenaltyV1Harness internal harness;
    PositionNFT internal nft;
    LocalPenaltyMockERC20V1 internal token;

    address internal constant USER = address(0xA11CE);
    address internal constant ENFORCER = address(0xBEEF);
    address internal constant TREASURY = address(0x9999);

    uint256 internal constant PID = 1;

    function setUp() public {
        vm.warp(10 days);
        token = new LocalPenaltyMockERC20V1("Test Token", "TEST", 18);
        nft = new PositionNFT();
        harness = new PenaltyV1Harness();

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(harness));
        harness.initPool(PID, address(token), 2, 3);

        harness.setTreasury(TREASURY);
        harness.setFeeSplits(10_000, 0);
    }

    function test_penalizeRolling_clearsLoanAndPaysEnforcer() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 5, 100 ether);

        uint256 enforcerBefore = token.balanceOf(ENFORCER);
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);

        Types.RollingCreditLoan memory loan = harness.getRollingLoan(PID, key);
        assertFalse(loan.active);
        assertEq(loan.principalRemaining, 0);

        uint256 penalty = (100 ether * 500) / 10_000;
        uint256 enforcerShare = penalty / 10;
        assertEq(token.balanceOf(ENFORCER) - enforcerBefore, enforcerShare);
        assertEq(harness.getPrincipal(PID, key), 45 ether);
    }

    function test_penalizeFixed_closesLoanAndReducesPrincipal() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp - 1, 100 ether);

        uint256 enforcerBefore = token.balanceOf(ENFORCER);
        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);

        Types.FixedTermLoan memory loan = harness.getFixedLoan(PID, 1);
        assertTrue(loan.closed);
        assertEq(loan.principalRemaining, 0);

        uint256 penalty = (100 ether * 500) / 10_000;
        uint256 enforcerShare = penalty / 10;
        assertEq(token.balanceOf(ENFORCER) - enforcerBefore, enforcerShare);
        assertEq(harness.getPrincipal(PID, key), 75 ether);
    }

    function test_penalizeRolling_revertsWhenEncumberedExceedsPrincipal() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 5, 100 ether);
        harness.setDirectLocked(PID, key, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 100 ether, 100 ether));
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenLoanNotActive() public {
        (uint256 tokenId,) = _mintAndSeed(100 ether);

        vm.expectRevert("PositionNFT: loan not active");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenNoPrincipalRemaining() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 0, 5, 100 ether);

        vm.expectRevert("PositionNFT: no principal");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenNotDelinquent() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 2, 100 ether);

        vm.expectRevert("PositionNFT: not delinquent");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenNotDepositBacked() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 5, 100 ether);
        harness.setRollingLoanDepositBacked(PID, key, false);

        vm.expectRevert("PositionNFT: only deposit-backed loans supported");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenInsufficientPoolLiquidity() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 5, 100 ether);
        harness.setTrackedBalance(PID, 4 ether);

        vm.expectRevert("PositionNFT: insufficient pool liquidity");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeRolling_revertsWhenInsufficientContractBalance() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedRollingLoan(PID, key, 50 ether, 5, 100 ether);
        harness.drainUnderlying(PID, address(0xCAFE), 396 ether);

        vm.expectRevert("PositionNFT: insufficient contract balance");
        harness.penalizePositionRolling(tokenId, PID, ENFORCER);
    }

    function test_penalizeFixed_revertsWhenWrongBorrower() public {
        (uint256 tokenId,) = _mintAndSeed(100 ether);
        uint256 tokenIdTwo = harness.mintFor(address(0xB0B), PID);
        bytes32 otherKey = nft.getPositionKey(tokenIdTwo);
        harness.seedPosition(PID, otherKey, 100 ether);
        harness.joinPool(otherKey, PID);

        harness.seedFixedLoan(PID, otherKey, 1, 20 ether, block.timestamp - 1, 100 ether);

        vm.expectRevert("PositionNFT: not borrower");
        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);
    }

    function test_penalizeFixed_revertsWhenLoanClosed() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp - 1, 100 ether);
        harness.setFixedLoanClosed(PID, 1, true);

        vm.expectRevert("PositionNFT: loan closed");
        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);
    }

    function test_penalizeFixed_revertsWhenNotExpired() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp + 1 days, 100 ether);

        vm.expectRevert("PositionNFT: not expired");
        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);
    }

    function test_penalizeFixed_revertsWhenInsufficientAvailableCollateral() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(100 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp - 1, 100 ether);
        harness.setDirectLocked(PID, key, 80 ether);

        vm.expectRevert("PositionNFT: insufficient collateral for penalty");
        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);
    }

    function test_penalizeFixed_updatesLoanIndexesAndActiveCreditDeltas() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(120 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp - 1, 100 ether);
        harness.seedFixedLoan(PID, key, 2, 30 ether, block.timestamp + 2 days, 120 ether);
        harness.seedDebtState(PID, key, 35 ether, block.timestamp - 2 days, LibFeeIndex.INDEX_SCALE);
        harness.setActiveCreditPrincipalTotal(PID, 35 ether);

        uint256[] memory beforeIds = harness.getFixedLoanIds(PID, key);
        assertEq(beforeIds.length, 2);
        assertEq(beforeIds[0], 1);
        assertEq(beforeIds[1], 2);
        assertEq(harness.getLoanIdIndex(PID, key, 1), 0);
        assertEq(harness.getLoanIdIndex(PID, key, 2), 1);
        assertEq(harness.getActiveFixedLoanCount(PID, key), 2);
        assertEq(harness.getFixedTermPrincipalRemaining(PID, key), 50 ether);
        assertEq(harness.getActiveCreditPrincipalTotal(PID), 35 ether);

        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);

        Types.FixedTermLoan memory defaulted = harness.getFixedLoan(PID, 1);
        assertTrue(defaulted.closed);
        assertEq(defaulted.principalRemaining, 0);

        uint256[] memory afterIds = harness.getFixedLoanIds(PID, key);
        assertEq(afterIds.length, 1);
        assertEq(afterIds[0], 2);
        assertEq(harness.getLoanIdIndex(PID, key, 2), 0);
        assertEq(harness.getActiveFixedLoanCount(PID, key), 1);
        assertEq(harness.getFixedTermPrincipalRemaining(PID, key), 30 ether);

        Types.ActiveCreditState memory debtState = harness.getDebtState(PID, key);
        assertEq(debtState.principal, 15 ether);
        assertEq(harness.getActiveCreditPrincipalTotal(PID), 15 ether);
    }

    function test_penalizeFixed_activeCreditReductionClampsToZero() public {
        (uint256 tokenId, bytes32 key) = _mintAndSeed(120 ether);
        harness.seedFixedLoan(PID, key, 1, 20 ether, block.timestamp - 1, 100 ether);
        harness.seedDebtState(PID, key, 10 ether, block.timestamp - 1 days, LibFeeIndex.INDEX_SCALE);
        harness.setActiveCreditPrincipalTotal(PID, 10 ether);

        harness.penalizePositionFixed(tokenId, PID, 1, ENFORCER);

        Types.ActiveCreditState memory debtState = harness.getDebtState(PID, key);
        assertEq(debtState.principal, 0);
        assertEq(debtState.startTime, 0);
        assertEq(debtState.indexSnapshot, 0);
        assertEq(harness.getActiveCreditPrincipalTotal(PID), 0);
    }

    function _mintAndSeed(uint256 principal) internal returns (uint256 tokenId, bytes32 key) {
        tokenId = harness.mintFor(USER, PID);
        key = nft.getPositionKey(tokenId);
        harness.seedPosition(PID, key, principal);
        harness.joinPool(key, PID);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionViewFacet} from "../../src/views/PositionViewFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract PositionViewFacetHarness is PositionViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }

    function seedFixedLoan(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 principal, uint40 expiry) external {
        Types.PoolData storage p = s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = expiry;
        loan.apyBps = 1000;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = 0;
        p.activeFixedLoanCount[positionKey] = 1;
    }

    function seedRolling(uint256 pid, bytes32 positionKey, uint256 principal, uint8 missedPayments) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp - 90 days);
        loan.lastAccrualTs = uint40(block.timestamp - 90 days);
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 30 days;
        loan.depositBacked = true;
        loan.active = true;
    }

    function setDirectBorrowed(bytes32 key, uint256 pid, uint256 amount) external {
        LibDirectStorage.directStorage().directBorrowedPrincipal[key][pid] = amount;
    }

    function setDirectLocked(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directLocked = amount;
    }

    function setDirectOfferEscrow(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directOfferEscrow = amount;
    }

    function setDirectLent(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directLent = amount;
    }

    function setIndexEncumbered(bytes32 key, uint256 pid, uint256 indexId, uint256 amount) external {
        // Set desired value by first zeroing (fresh harness) then encumbering
        LibIndexEncumbrance.encumber(key, pid, indexId, amount);
    }

    function setFeeIndex(
        uint256 pid,
        uint256 feeIndex,
        bytes32 positionKey,
        uint256 userFeeIndex,
        uint256 accruedYield
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.feeIndex = feeIndex;
        p.userFeeIndex[positionKey] = userFeeIndex;
        p.userAccruedYield[positionKey] = accruedYield;
    }
}

contract PositionViewFacetTest is Test {
    PositionViewFacetHarness internal viewFacet;
    PositionNFT internal nft;
    MockERC20 internal token;

    uint256 constant PID = 1;
    address internal user = address(0xBEEF);

    function setUp() public {
        viewFacet = new PositionViewFacetHarness();
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);

        viewFacet.configurePositionNFT(address(nft));
        nft.setMinter(address(this));
        viewFacet.initPool(PID, address(token));
    }

    function test_getPositionStateReturnsPrincipalAndDebt() public {
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);

        viewFacet.seedPosition(PID, key, 100 ether);
        viewFacet.setDirectLocked(key, PID, 10 ether); // encumbrance only
        viewFacet.setDirectBorrowed(key, PID, 40 ether);

        Types.PositionState memory state = viewFacet.getPositionState(tokenId, PID);
        assertEq(state.principal, 100 ether, "principal");
        assertEq(state.totalDebt, 40 ether, "total debt counts direct borrowed not locks");
        assertEq(state.solvencyRatio, (100 ether * 10_000) / 40 ether, "solvency ratio");
    }

    function test_getPositionEncumbranceAggregatesComponents() public {
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);

        viewFacet.seedPosition(PID, key, 100 ether);
        viewFacet.setDirectLocked(key, PID, 5 ether);
        viewFacet.setDirectLent(key, PID, 4 ether);
        viewFacet.setDirectOfferEscrow(key, PID, 3 ether);
        viewFacet.setIndexEncumbered(key, PID, 1, 7 ether);

        Types.PositionEncumbrance memory enc = viewFacet.getPositionEncumbrance(tokenId, PID);
        assertEq(enc.directLocked, 5 ether, "direct locked");
        assertEq(enc.directLent, 4 ether, "direct lent");
        assertEq(enc.directOfferEscrow, 3 ether, "offer escrow");
        assertEq(enc.indexEncumbered, 7 ether, "index encumbrance");
        assertEq(enc.totalEncumbered, 19 ether, "total encumbered");
    }

    function test_getPositionStatesBatchesPools() public {
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        uint256 pid2 = 2;

        viewFacet.initPool(pid2, address(token));
        viewFacet.seedPosition(PID, key, 50 ether);
        viewFacet.seedPosition(pid2, key, 25 ether);

        uint256[] memory pids = new uint256[](2);
        pids[0] = PID;
        pids[1] = pid2;

        Types.PositionState[] memory states = viewFacet.getPositionStates(tokenId, pids);
        assertEq(states.length, 2, "states length");
        assertEq(states[0].principal, 50 ether, "pid1 principal");
        assertEq(states[1].principal, 25 ether, "pid2 principal");
    }

    function test_getPositionLoanIdsPaginates() public {
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        viewFacet.seedPosition(PID, key, 10 ether);
        viewFacet.seedFixedLoan(PID, key, 1, 5 ether, uint40(block.timestamp + 1 days));
        viewFacet.seedFixedLoan(PID, key, 2, 6 ether, uint40(block.timestamp + 2 days));
        viewFacet.seedFixedLoan(PID, key, 3, 7 ether, uint40(block.timestamp + 3 days));

        vm.prank(user);
        (uint256[] memory page, uint256 total, bool hasMore) = viewFacet.getPositionLoanIds(tokenId, PID, 1, 2);
        assertEq(total, 3, "total loans");
        assertFalse(hasMore, "has more");
        assertEq(page.length, 2, "page length");
        assertEq(page[0], 2);
        assertEq(page[1], 3);
    }

    function test_isPositionDelinquentFlagsRolling() public {
        vm.warp(100 days);
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        viewFacet.seedPosition(PID, key, 50 ether);
        viewFacet.seedRolling(PID, key, 20 ether, 4);

        assertTrue(viewFacet.isPositionDelinquent(tokenId, PID), "should be delinquent");
    }

    function test_getPositionStateIncludesAccruedYieldAcrossPools() public {
        uint256 tokenId1 = nft.mint(user, PID);
        uint256 tokenId2 = nft.mint(user, PID + 1);
        bytes32 key1 = nft.getPositionKey(tokenId1);
        bytes32 key2 = nft.getPositionKey(tokenId2);

        viewFacet.initPool(PID + 1, address(token));
        viewFacet.seedPosition(PID, key1, 100 ether);
        viewFacet.seedPosition(PID + 1, key2, 50 ether);

        viewFacet.setFeeIndex(
            PID, LibFeeIndex.INDEX_SCALE + 1e17, key1, LibFeeIndex.INDEX_SCALE, 0
        ); // +10% yield
        viewFacet.setFeeIndex(PID + 1, LibFeeIndex.INDEX_SCALE, key2, LibFeeIndex.INDEX_SCALE, 1 ether);

        Types.PositionState memory state1 = viewFacet.getPositionState(tokenId1, PID);
        Types.PositionState memory state2 = viewFacet.getPositionState(tokenId2, PID + 1);

        assertEq(state1.accruedYield, 10 ether, "pool1 yield");
        assertEq(state2.accruedYield, 1 ether, "pool2 accrued carried through");
    }

    function test_getPositionLoanSummaryAggregatesRollingFixedDirectAndDelinquency() public {
        vm.warp(100 days);
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        viewFacet.seedPosition(PID, key, 100 ether);
        viewFacet.seedRolling(PID, key, 20 ether, 4); // delinquent
        viewFacet.seedFixedLoan(PID, key, 1, 7 ether, uint40(block.timestamp - 1 days)); // expired
        viewFacet.seedFixedLoan(PID, key, 2, 3 ether, uint40(block.timestamp + 1 days));
        viewFacet.setDirectBorrowed(key, PID, 5 ether);

        (uint256 totalLoans, uint256 activeLoans, uint256 totalDebt, uint256 nextExpiry, bool delinquent) =
            viewFacet.getPositionLoanSummary(tokenId, PID);

        assertEq(totalLoans, 2, "fixed loans counted");
        assertEq(activeLoans, 2, "active fixed loans");
        assertEq(totalDebt, 35 ether, "rolling+fixed+direct borrowed");
        assertEq(nextExpiry, uint40(block.timestamp - 1 days), "earliest expiry");
        assertTrue(delinquent, "delinquency from rolling/fixed");
    }

    function test_isPositionDelinquentFlagsExpiredFixedLoan() public {
        vm.warp(10 days);
        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        viewFacet.seedPosition(PID, key, 10 ether);
        viewFacet.seedFixedLoan(PID, key, 99, 5 ether, uint40(block.timestamp - 1 days));

        assertTrue(viewFacet.isPositionDelinquent(tokenId, PID), "expired fixed loan delinquent");
    }

    function test_getPositionSolvencyIsPoolScoped() public {
        uint256 tokenId1 = nft.mint(user, PID);
        uint256 tokenId2 = nft.mint(user, PID + 1);
        bytes32 key1 = nft.getPositionKey(tokenId1);
        bytes32 key2 = nft.getPositionKey(tokenId2);

        viewFacet.initPool(PID + 1, address(token));
        viewFacet.seedPosition(PID, key1, 60 ether);
        viewFacet.seedPosition(PID + 1, key2, 40 ether);
        viewFacet.setDirectBorrowed(key2, PID + 1, 30 ether);

        (uint256 principal1, uint256 debt1, uint256 ratio1) = viewFacet.getPositionSolvency(tokenId1, PID);
        (uint256 principal2, uint256 debt2, uint256 ratio2) =
            viewFacet.getPositionSolvency(tokenId2, PID + 1);

        assertEq(principal1, 60 ether, "pool1 principal");
        assertEq(debt1, 0, "pool1 debt isolated");
        assertEq(ratio1, type(uint256).max, "pool1 ratio");

        assertEq(principal2, 40 ether, "pool2 principal");
        assertEq(debt2, 30 ether, "pool2 debt");
        assertEq(ratio2, (principal2 * 10_000) / debt2, "pool2 ratio");
    }
}

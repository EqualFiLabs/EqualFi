// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LiquidityViewFacet} from "../../src/views/LiquidityViewFacet.sol";
import {PoolUtilizationViewFacet} from "../../src/views/PoolUtilizationViewFacet.sol";
import {PositionViewFacet} from "../../src/views/PositionViewFacet.sol";

import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract LocalViewsMockERC20V1 is ERC20 {
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

contract LiquidityViewV1Harness is LiquidityViewFacet {
    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setUserState(
        uint256 pid,
        bytes32 key,
        uint256 principal,
        uint256 accruedYield,
        uint256 userFeeIndex
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[key] = principal;
        p.userAccruedYield[key] = accruedYield;
        p.userFeeIndex[key] = userFeeIndex;
    }

    function setAccrued(uint256 pid, bytes32 key, uint256 accruedYield) external {
        LibAppStorage.s().pools[pid].userAccruedYield[key] = accruedYield;
    }
}

contract PoolUtilizationViewV1Harness is PoolUtilizationViewFacet {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
    }

    function setConfig(uint256 pid, bool isCapped, uint256 depositCap, uint256 maxUserCount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.poolConfig.isCapped = isCapped;
        p.poolConfig.depositCap = depositCap;
        p.poolConfig.maxUserCount = maxUserCount;
    }

    function setTotals(uint256 pid, uint256 totalDeposits, uint256 userCount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.userCount = userCount;
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }
}

contract PositionViewV1Harness is PositionViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }

    function seedRollingLoan(uint256 pid, bytes32 positionKey, uint256 principalRemaining, uint256 missedPayments)
        external
    {
        if (missedPayments > type(uint8).max) revert();
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp - 90 days);
        loan.lastAccrualTs = uint40(block.timestamp - 90 days);
        loan.apyBps = 1000;
        loan.missedPayments = uint8(missedPayments);
        loan.paymentIntervalSecs = 30 days;
        loan.depositBacked = true;
        loan.active = true;
    }

    function seedFixedLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 principalRemaining,
        uint256 expiry
    ) external {
        if (expiry > type(uint40).max) revert();
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = uint40(expiry);
        loan.apyBps = 1000;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;

        uint256 idx = p.userFixedLoanIds[positionKey].length;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = idx;
        p.activeFixedLoanCount[positionKey] += 1;
        p.fixedTermPrincipalRemaining[positionKey] += principalRemaining;
    }

    function setDirectBorrowed(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid] = amount;
    }

    function setDirectLocked(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
    }

    function setDirectLent(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLent = amount;
    }

    function setDirectOfferEscrow(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = amount;
    }

    function setModuleEncumbered(uint256 pid, bytes32 positionKey, uint256 moduleId, uint256 amount) external {
        if (amount == 0) return;
        LibEncumbrance.encumberModule(positionKey, pid, moduleId, amount);
    }

    function setIndexEncumbered(uint256 pid, bytes32 positionKey, uint256 indexId, uint256 amount) external {
        if (amount == 0) return;
        LibIndexEncumbrance.encumber(positionKey, pid, indexId, amount);
    }
}

contract LiquidityAndPositionViewsV1Test is Test {
    LiquidityViewV1Harness internal liquidityHarness;
    PoolUtilizationViewV1Harness internal utilizationHarness;
    PositionViewV1Harness internal positionHarness;

    PositionNFT internal nft;
    LocalViewsMockERC20V1 internal token;

    uint256 internal constant PID_LIQ = 1;
    uint256 internal constant PID_UTIL = 2;
    uint256 internal constant PID_POS = 3;
    address internal constant USER = address(0xBEEF);

    function setUp() public {
        vm.warp(200 days);
        liquidityHarness = new LiquidityViewV1Harness();
        utilizationHarness = new PoolUtilizationViewV1Harness();
        positionHarness = new PositionViewV1Harness();

        token = new LocalViewsMockERC20V1("Views Token", "VIEW", 18);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        positionHarness.configurePositionNFT(address(nft));
    }

    function test_liquidityViews_readAccruedBalancesAndLiquidity() public {
        bytes32 keyA = keccak256("key-a");
        bytes32 keyB = keccak256("key-b");

        liquidityHarness.seedPool(PID_LIQ, address(token), 1_000 ether);
        liquidityHarness.setUserState(PID_LIQ, keyA, 100 ether, 10 ether, LibFeeIndex.INDEX_SCALE);
        liquidityHarness.setAccrued(PID_LIQ, keyB, 15 ether);
        token.mint(address(liquidityHarness), 333 ether);

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keyA;
        keys[1] = keyB;

        assertEq(liquidityHarness.sumAccruedYield(PID_LIQ, keys), 25 ether);
        assertEq(liquidityHarness.totalAvailableLiquidity(PID_LIQ), 333 ether);
        assertEq(liquidityHarness.getTotalPoolDeposits(PID_LIQ), 1_000 ether);
        assertEq(liquidityHarness.pendingYield(PID_LIQ, keyA), 10 ether);

        (uint256 principal, uint256 accrued, uint256 userFeeIndex, uint256 globalFeeIndex) =
            liquidityHarness.getUserBalances(PID_LIQ, keyA);
        assertEq(principal, 100 ether);
        assertEq(accrued, 10 ether);
        assertEq(userFeeIndex, LibFeeIndex.INDEX_SCALE);
        assertEq(globalFeeIndex, LibFeeIndex.INDEX_SCALE);
    }

    function test_poolUtilizationViews_capacityAndDepositChecks() public {
        bytes32 existingUser = keccak256("existing");
        bytes32 newUser = keccak256("new");

        utilizationHarness.initPool(PID_UTIL, address(token));
        utilizationHarness.setTotals(PID_UTIL, 100 ether, 1);
        token.mint(address(utilizationHarness), 60 ether);

        (uint256 totalDeposits, uint256 totalBorrowed, uint256 availableLiquidity, uint256 utilizationBps,) =
            utilizationHarness.getPoolUtilization(PID_UTIL);
        assertEq(totalDeposits, 100 ether);
        assertEq(totalBorrowed, 40 ether);
        assertEq(availableLiquidity, 60 ether);
        assertEq(utilizationBps, 4000);

        utilizationHarness.setConfig(PID_UTIL, true, 10 ether, 1);
        utilizationHarness.setUserPrincipal(PID_UTIL, existingUser, 6 ether);

        (bool isCapped, uint256 depositCap, uint256 depositsNow, uint256 userCountNow, uint256 maxUserCountNow) =
            utilizationHarness.getPoolCapacity(PID_UTIL);
        assertTrue(isCapped);
        assertEq(depositCap, 10 ether);
        assertEq(depositsNow, 100 ether);
        assertEq(userCountNow, 1);
        assertEq(maxUserCountNow, 1);

        (uint256 availableForBorrow, uint256 totalLiquidity, uint256 reservedForWithdrawals) =
            utilizationHarness.getAvailableLiquidity(PID_UTIL);
        assertEq(availableForBorrow, 0);
        assertEq(totalLiquidity, 60 ether);
        assertEq(reservedForWithdrawals, 100 ether);

        (,, uint256 maxUsers, uint256 avgDeposit, uint256 utilBps) = utilizationHarness.getPoolStats(PID_UTIL);
        assertEq(maxUsers, 1);
        assertEq(avgDeposit, 100 ether);
        assertEq(utilBps, 4000);

        token.mint(address(utilizationHarness), 50 ether);
        (availableForBorrow, totalLiquidity, reservedForWithdrawals) = utilizationHarness.getAvailableLiquidity(PID_UTIL);
        assertEq(availableForBorrow, 10 ether);
        assertEq(totalLiquidity, 110 ether);
        assertEq(reservedForWithdrawals, 100 ether);

        (bool allowed, uint256 maxAllowed, string memory reason) =
            utilizationHarness.canDeposit(PID_UTIL, existingUser, 5 ether);
        assertFalse(allowed);
        assertEq(maxAllowed, 4 ether);
        assertEq(reason, "Exceeds user deposit cap");

        (allowed, maxAllowed, reason) = utilizationHarness.canDeposit(PID_UTIL, existingUser, 4 ether);
        assertTrue(allowed);
        assertEq(maxAllowed, 4 ether);
        assertEq(reason, "");

        (allowed,, reason) = utilizationHarness.canDeposit(PID_UTIL, newUser, 1 ether);
        assertFalse(allowed);
        assertEq(reason, "Pool at max user capacity");

        (,, maxUsers, avgDeposit, utilBps) = utilizationHarness.getPoolStats(PID_UTIL);
        assertEq(maxUsers, 1);
        assertEq(avgDeposit, 100 ether);
        assertEq(utilBps, 0);
    }

    function test_positionViews_stateLoanSummaryAndEncumbrance() public {
        positionHarness.initPool(PID_POS, address(token));

        uint256 tokenId = nft.mint(USER, PID_POS);
        bytes32 key = nft.getPositionKey(tokenId);
        uint40 expired = uint40(block.timestamp - 1 days);
        uint40 future = uint40(block.timestamp + 1 days);

        positionHarness.seedPosition(PID_POS, key, 100 ether);
        positionHarness.seedRollingLoan(PID_POS, key, 20 ether, 4);
        positionHarness.seedFixedLoan(PID_POS, key, 1, 7 ether, expired);
        positionHarness.seedFixedLoan(PID_POS, key, 2, 3 ether, future);
        positionHarness.setDirectBorrowed(PID_POS, key, 5 ether);

        positionHarness.setDirectLocked(PID_POS, key, 5 ether);
        positionHarness.setDirectLent(PID_POS, key, 4 ether);
        positionHarness.setDirectOfferEscrow(PID_POS, key, 3 ether);
        positionHarness.setIndexEncumbered(PID_POS, key, 1, 7 ether);
        positionHarness.setModuleEncumbered(PID_POS, key, 2, 11 ether);

        Types.PositionState memory state = positionHarness.getPositionState(tokenId, PID_POS);
        assertEq(state.principal, 100 ether);
        assertEq(state.totalDebt, 35 ether);
        uint256 expectedRatio = (uint256(100 ether) * 10_000) / uint256(35 ether);
        assertEq(state.solvencyRatio, expectedRatio);
        assertTrue(state.isDelinquent);
        assertTrue(state.eligibleForPenalty);

        (uint256 totalLoans, uint256 activeLoans, uint256 totalDebt, uint256 nextExpiry, bool hasDelinquent) =
            positionHarness.getPositionLoanSummary(tokenId, PID_POS);
        assertEq(totalLoans, 2);
        assertEq(activeLoans, 2);
        assertEq(totalDebt, 35 ether);
        assertEq(nextExpiry, expired);
        assertTrue(hasDelinquent);
        assertTrue(positionHarness.isPositionDelinquent(tokenId, PID_POS));

        Types.PositionEncumbrance memory enc = positionHarness.getPositionEncumbrance(tokenId, PID_POS);
        assertEq(enc.directLocked, 5 ether);
        assertEq(enc.directLent, 4 ether);
        assertEq(enc.directOfferEscrow, 3 ether);
        assertEq(enc.indexEncumbered, 7 ether);
        assertEq(enc.moduleEncumbered, 11 ether);
        assertEq(enc.totalEncumbered, 30 ether);

        vm.prank(USER);
        (uint256[] memory loanIds, uint256 totalCount, bool hasMore) =
            positionHarness.getPositionLoanIds(tokenId, PID_POS, 0, 2);
        assertEq(totalCount, 2);
        assertEq(loanIds.length, 2);
        assertEq(loanIds[0], 1);
        assertEq(loanIds[1], 2);
        assertFalse(hasMore);

        Types.PositionMetadata memory metadata = positionHarness.getPositionMetadata(tokenId, PID_POS);
        assertEq(metadata.tokenId, tokenId);
        assertEq(metadata.poolId, PID_POS);
        assertEq(metadata.underlying, address(token));
        assertEq(metadata.currentOwner, USER);
    }

    function test_positionViews_batchStatesAndLoanDetails() public {
        positionHarness.initPool(PID_POS, address(token));

        uint256 tokenId = nft.mint(USER, PID_POS);
        bytes32 key = nft.getPositionKey(tokenId);
        uint40 future = uint40(block.timestamp + 1 days);

        positionHarness.seedPosition(PID_POS, key, 50 ether);
        positionHarness.seedFixedLoan(PID_POS, key, 1, 5 ether, future);
        positionHarness.seedFixedLoan(PID_POS, key, 2, 7 ether, future);

        uint256[] memory pids = new uint256[](1);
        pids[0] = PID_POS;
        Types.PositionState[] memory states = positionHarness.getPositionStates(tokenId, pids);
        assertEq(states.length, 1);
        assertEq(states[0].tokenId, tokenId);
        assertEq(states[0].poolId, PID_POS);
        assertEq(states[0].principal, 50 ether);
        assertEq(states[0].totalDebt, 12 ether);

        uint256[] memory loanIds = new uint256[](2);
        loanIds[0] = 1;
        loanIds[1] = 2;
        Types.FixedTermLoan[] memory loans = positionHarness.getLoansDetails(PID_POS, loanIds);
        assertEq(loans.length, 2);
        assertEq(loans[0].borrower, key);
        assertEq(loans[1].borrower, key);
        assertEq(loans[0].principalRemaining, 5 ether);
        assertEq(loans[1].principalRemaining, 7 ether);

        loanIds[1] = 999;
        vm.expectRevert("PositionNFT: loan not found");
        positionHarness.getLoansDetails(PID_POS, loanIds);

        bytes4[] memory selectors = positionHarness.selectors();
        assertEq(selectors.length, 9);
        assertEq(selectors[6], bytes4(keccak256("getPositionStates(uint256,uint256[])")));
    }
}

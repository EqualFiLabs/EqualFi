// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";
import {
    DepositBelowMinimum,
    DepositCapExceeded,
    InsufficientPrincipal,
    InsufficientPoolLiquidity,
    UnexpectedMsgValue
} from "../../src/libraries/Errors.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

struct PositionSnapshot {
    uint256 principal;
    uint256 accruedYield;
    uint256 totalDeposits;
    uint256 trackedBalance;
    uint256 yieldReserve;
    uint256 userCount;
    uint256 feeIndex;
    uint256 maintenanceIndex;
    bool isMember;
}

/// @notice Harness exposing storage configuration and inspection for PositionManagementFacet
contract PositionManagementFacetHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }

    function setDepositCap(uint256 pid, bool isCapped, uint256 cap) external {
        Types.PoolData storage p = s().pools[pid];
        p.poolConfig.isCapped = isCapped;
        p.poolConfig.depositCap = cap;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPositionMintFee(address feeToken, uint256 feeAmount) external {
        LibAppStorage.s().positionMintFeeToken = feeToken;
        LibAppStorage.s().positionMintFeeAmount = feeAmount;
    }

    function setDefaultMaintenanceRate(uint16 rateBps) external {
        LibAppStorage.s().defaultMaintenanceRateBps = rateBps;
    }

    function setLastMaintenanceTimestamp(uint256 pid, uint64 ts) external {
        s().pools[pid].lastMaintenanceTimestamp = ts;
    }

    function setAccruedYield(uint256 pid, bytes32 positionKey, uint256 yieldAmount) external {
        Types.PoolData storage p = s().pools[pid];
        p.userAccruedYield[positionKey] = yieldAmount;
        p.yieldReserve += yieldAmount;
        p.trackedBalance += yieldAmount;
        MockERC20(p.underlying).mint(address(this), yieldAmount);
    }

    function setAccruedYieldNoBalance(uint256 pid, bytes32 positionKey, uint256 yieldAmount) external {
        Types.PoolData storage p = s().pools[pid];
        p.userAccruedYield[positionKey] = yieldAmount;
    }

    function addTrackedBalance(uint256 pid, uint256 amount) external {
        Types.PoolData storage p = s().pools[pid];
        p.trackedBalance += amount;
        MockERC20(p.underlying).mint(address(this), amount);
    }

    function setDirectLocks(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
    }

    function setDirectOfferEscrow(bytes32 positionKey, uint256 pid, uint256 escrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = escrowed;
    }

    function setDirectBorrowed(bytes32 positionKey, uint256 pid, uint256 borrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        ds.directBorrowedPrincipal[positionKey][pid] = borrowed;
    }

    function getTotalDebt(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = s().pools[pid];
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function snapshot(uint256 pid, bytes32 positionKey) external view returns (PositionSnapshot memory snap) {
        Types.PoolData storage p = s().pools[pid];
        snap.principal = p.userPrincipal[positionKey];
        snap.accruedYield = p.userAccruedYield[positionKey];
        snap.totalDeposits = p.totalDeposits;
        snap.trackedBalance = p.trackedBalance;
        snap.yieldReserve = p.yieldReserve;
        snap.userCount = p.userCount;
        snap.feeIndex = p.userFeeIndex[positionKey];
        snap.maintenanceIndex = p.userMaintenanceIndex[positionKey];
        snap.isMember = LibPoolMembership.isMember(positionKey, pid);
    }
}

/// @notice Unit tests for PositionManagementFacet lifecycle operations
/// @dev **Validates: Requirements 3.1, 7.1**
contract PositionManagementFacetUnitTest is Test {
    PositionNFT public nft;
    PositionManagementFacetHarness public facet;
    MockERC20 public token;

    address public user = address(0xA11CE);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        facet = new PositionManagementFacetHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, LTV_BPS);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function test_mintPosition_mintsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit PositionManagementFacet.PositionMinted(1, user, PID);

        vm.prank(user);
        uint256 tokenId = facet.mintPosition(PID);

        assertEq(nft.ownerOf(tokenId), user, "owner mismatch");
        assertEq(tokenId, 1, "tokenId mismatch");
    }

    function test_mintPosition_chargesEthFee() public {
        address treasury = address(0xBEEF);
        uint256 feeAmount = 0.2 ether;
        facet.setTreasury(treasury);
        facet.setPositionMintFee(address(0), feeAmount);
        vm.deal(user, feeAmount + 1 ether);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(user);
        facet.mintPosition{value: feeAmount}(PID);

        assertEq(treasury.balance - treasuryBefore, feeAmount, "treasury fee mismatch");
    }

    function test_mintPosition_revertsOnEthFeeIncorrectMsgValue() public {
        uint256 feeAmount = 0.1 ether;
        facet.setTreasury(address(0xBEEF));
        facet.setPositionMintFee(address(0), feeAmount);
        vm.deal(user, feeAmount + 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 0));
        facet.mintPosition(PID);
    }

    function test_mintPositionWithDeposit_chargesEthFee() public {
        address treasury = address(0xBEEF);
        uint256 feeAmount = 0.15 ether;
        uint256 depositAmount = 10 ether;
        facet.setTreasury(treasury);
        facet.setPositionMintFee(address(0), feeAmount);
        vm.deal(user, feeAmount + 1 ether);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit{value: feeAmount}(PID, depositAmount);

        bytes32 key = nft.getPositionKey(tokenId);
        PositionSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.principal, depositAmount, "principal mismatch");
        assertEq(treasury.balance - treasuryBefore, feeAmount, "treasury fee mismatch");
    }

    function test_mintPosition_chargesErc20Fee() public {
        address treasury = address(0xBEEF);
        uint256 feeAmount = 5 ether;
        facet.setTreasury(treasury);
        facet.setPositionMintFee(address(token), feeAmount);

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(user);
        facet.mintPosition(PID);

        assertEq(token.balanceOf(treasury) - treasuryBefore, feeAmount, "erc20 fee mismatch");
    }

    function test_mintPositionWithDeposit_chargesErc20Fee() public {
        address treasury = address(0xBEEF);
        uint256 feeAmount = 5 ether;
        uint256 depositAmount = 10 ether;
        facet.setTreasury(treasury);
        facet.setPositionMintFee(address(token), feeAmount);

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, depositAmount);

        bytes32 key = nft.getPositionKey(tokenId);
        PositionSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.principal, depositAmount, "principal mismatch");
        assertEq(token.balanceOf(treasury) - treasuryBefore, feeAmount, "erc20 fee mismatch");
    }

    function test_mintPositionWithDeposit_enforcesMin() public {
        // Raise min deposit to exercise DepositBelowMinimum path
        facet.initPool(PID, address(token), 5, 1, LTV_BPS);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DepositBelowMinimum.selector, 1, 5));
        facet.mintPositionWithDeposit(PID, 1);
    }

    function test_depositToPosition_updatesBalances() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 10 ether);

        vm.prank(user);
        facet.depositToPosition(tokenId, PID, 5 ether);

        PositionSnapshot memory snap = facet.snapshot(PID, nft.getPositionKey(tokenId));
        assertEq(snap.principal, 15 ether, "principal incorrect");
        assertEq(snap.totalDeposits, 15 ether, "totalDeposits incorrect");
        assertEq(snap.trackedBalance, 15 ether, "trackedBalance incorrect");
    }

    function test_withdrawFromPosition_respectsSolvencyAndUpdatesState() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 20 ether);

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.setAccruedYield(PID, positionKey, 4 ether);

        vm.prank(user);
        facet.withdrawFromPosition(tokenId, PID, 5 ether);

        PositionSnapshot memory snap = facet.snapshot(PID, positionKey);
        assertEq(snap.principal, 15 ether, "principal after withdraw");
        assertEq(snap.accruedYield, 3 ether, "accrued yield after withdraw");
        assertEq(snap.totalDeposits, 15 ether, "totalDeposits after withdraw");
        assertEq(snap.trackedBalance, 18 ether, "trackedBalance after withdraw");
    }

    function test_rollYieldToPosition_movesYieldToPrincipal() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 10 ether);

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.setAccruedYield(PID, positionKey, 3 ether);

        vm.prank(user);
        facet.rollYieldToPosition(tokenId, PID);

        PositionSnapshot memory snap = facet.snapshot(PID, positionKey);
        assertEq(snap.principal, 13 ether, "principal after roll");
        assertEq(snap.accruedYield, 0, "yield after roll");
        assertEq(snap.totalDeposits, 13 ether, "totalDeposits after roll");
    }

    function test_rollYieldToPosition_revertsWhenYieldExceedsTrackedBalance() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 10 ether);

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.setAccruedYieldNoBalance(PID, positionKey, 3 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolLiquidity.selector, 3 ether, 0));
        facet.rollYieldToPosition(tokenId, PID);
    }

    function test_rollYieldToPosition_consumesYieldReserve() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 10 ether);

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.setAccruedYield(PID, positionKey, 3 ether);

        vm.prank(user);
        facet.rollYieldToPosition(tokenId, PID);

        PositionSnapshot memory snap = facet.snapshot(PID, positionKey);
        assertEq(snap.principal, 13 ether, "principal after roll");
        assertEq(snap.accruedYield, 0, "yield after roll");
        assertEq(snap.totalDeposits, 13 ether, "totalDeposits after roll");
        assertEq(snap.yieldReserve, 0, "yield reserve cleared");
    }

    function test_cleanupMembership_succeedsWhenNoObligations() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 5 ether);

        vm.prank(user);
        facet.withdrawFromPosition(tokenId, PID, 5 ether);

        vm.prank(user);
        facet.cleanupMembership(tokenId, PID);

        PositionSnapshot memory snap = facet.snapshot(PID, nft.getPositionKey(tokenId));
        assertFalse(snap.isMember, "membership should be cleared");
        assertEq(snap.userCount, 0, "userCount not decremented");
    }

    function test_withdraw_appliesMaintenanceAccrualAndKeepsTrackedBalanced() public {
        address foundation = address(0xFEE1);
        facet.setFoundationReceiver(foundation);
        facet.setDefaultMaintenanceRate(3650); // 10% annualized for easier math

        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 100 ether);
        bytes32 key = nft.getPositionKey(tokenId);

        vm.warp(20 days);
        facet.setLastMaintenanceTimestamp(PID, uint64(block.timestamp - 10 days));

        PositionSnapshot memory beforeSnap = facet.snapshot(PID, key);
        uint256 foundationBefore = token.balanceOf(foundation);

        vm.prank(user);
        facet.withdrawFromPosition(tokenId, PID, 10 ether);

        PositionSnapshot memory afterSnap = facet.snapshot(PID, key);
        uint256 foundationPaid = token.balanceOf(foundation) - foundationBefore;

        assertGt(foundationPaid, 0, "maintenance should be paid");
        assertGt(afterSnap.maintenanceIndex, LibFeeIndex.INDEX_SCALE, "maintenance index advanced");

        assertLe(afterSnap.trackedBalance, beforeSnap.trackedBalance, "tracked should not increase");
        uint256 trackedDelta = beforeSnap.trackedBalance - afterSnap.trackedBalance;
        assertEq(trackedDelta, foundationPaid + 10 ether, "tracked balance covers maintenance + withdrawal");

        assertLe(afterSnap.principal, beforeSnap.principal, "principal should not increase");
        uint256 totalReduction = beforeSnap.principal - afterSnap.principal;
        assertEq(totalReduction, foundationPaid + 10 ether, "principal reduced by maintenance + withdrawal");
    }

    function test_withdrawRespectsDirectLocksAndUserCount() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 40 ether);
        bytes32 key = nft.getPositionKey(tokenId);

        facet.setDirectLocks(key, PID, 10 ether, 5 ether); // locked + lent = 15
        facet.setDirectBorrowed(key, PID, 15 ether);

        assertEq(facet.getTotalDebt(key, PID), 15 ether, "total debt with direct borrow");

        // With LTV 80%, direct debt 15 requires at least 18.75 principal to remain
        vm.prank(user);
        vm.expectRevert(); // exceeds solvency
        facet.withdrawFromPosition(tokenId, PID, 25 ether);

        vm.prank(user);
        facet.withdrawFromPosition(tokenId, PID, 20 ether);

        PositionSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.principal, 20 ether, "principal reduced respecting solvency");
        assertEq(snap.userCount, 1, "userCount should not decrement while locked remains");

        vm.prank(user);
        vm.expectRevert(); // would violate solvency given remaining debt
        facet.withdrawFromPosition(tokenId, PID, 6 ether);
    }

    function test_closePoolPosition_skipsMembershipClearWhenDirectCommitmentsExist() public {
        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 100 ether);
        bytes32 key = nft.getPositionKey(tokenId);

        facet.setDirectLocks(key, PID, 30 ether, 0);
        facet.setDirectOfferEscrow(key, PID, 10 ether);

        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        facet.closePoolPosition(tokenId, PID);

        PositionSnapshot memory snap = facet.snapshot(PID, key);
        assertEq(snap.principal, 40 ether, "principal left for direct commitments");
        assertTrue(snap.isMember, "membership retained with commitments");
        assertEq(token.balanceOf(user) - balanceBefore, 60 ether, "withdraws available principal");
    }

    function test_depositCapEnforcedWithDirectLocks() public {
        facet.setDepositCap(PID, true, 50 ether);

        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, 40 ether);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.setDirectLocks(key, PID, 30 ether, 0);

        vm.prank(user);
        facet.depositToPosition(tokenId, PID, 9 ether);
        assertEq(facet.snapshot(PID, key).principal, 49 ether, "principal after deposit");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DepositCapExceeded.selector, 60 ether, 50 ether));
        facet.depositToPosition(tokenId, PID, 11 ether);
    }

    function test_deposit_feeOnTransferCreditsReceived() public {
        // Use a fee-on-transfer token that charges 5% to a sink
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("Fee", "FEE", 18, 0, 500, address(0xBEEF));
        feeToken.mint(user, 100 ether);
        feeToken.mint(address(facet), 1 ether); // seed pool with token
        // Re-init pool 2 with fee token for this test
        uint256 feePid = 2;
        facet.initPool(feePid, address(feeToken), 1, 1, LTV_BPS);

        vm.prank(user);
        feeToken.approve(address(facet), type(uint256).max);

        vm.prank(user);
        uint256 tokenId = facet.mintPosition(feePid);
        bytes32 key = nft.getPositionKey(tokenId);

        // Deposit 10 ether; with 5% fee only 9.5 should be credited
        vm.prank(user);
        facet.depositToPosition(tokenId, feePid, 10 ether);

        PositionSnapshot memory snap = facet.snapshot(feePid, key);
        assertEq(snap.principal, 9.5 ether, "principal credits received amount");
        assertEq(snap.totalDeposits, 9.5 ether, "totalDeposits aligns");
        assertEq(snap.trackedBalance, 9.5 ether, "trackedBalance aligns");
    }
}

/// @notice Property tests ensuring PositionManagementFacet behaviors stay in parity with direct locks present
/// @dev Fuzzes lifecycle flows with direct locked/lent balances and compares mirrored facets
contract PositionManagementFacetPropertyTest is Test {
    PositionNFT public nft;
    PositionNFT public mirrorNft;
    PositionManagementFacetHarness public facet;
    PositionManagementFacetHarness public mirror;
    MockERC20 public token;

    address public user = address(0xA11CE);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        mirrorNft = new PositionNFT();
        facet = new PositionManagementFacetHarness();
        mirror = new PositionManagementFacetHarness();

        facet.configurePositionNFT(address(nft));
        mirror.configurePositionNFT(address(mirrorNft));
        nft.setMinter(address(facet));
        mirrorNft.setMinter(address(mirror));
        facet.initPool(PID, address(token), 1, 1, LTV_BPS);
        mirror.initPool(PID, address(token), 1, 1, LTV_BPS);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
        vm.prank(user);
        token.approve(address(mirror), type(uint256).max);
    }

    function testFuzz_BehavioralEquivalenceWithDirectLocks(
        uint256 deposit1,
        uint256 deposit2,
        uint256 yieldAccrued,
        uint256 lockedDirect,
        uint256 lentDirect,
        uint256 withdrawPrincipal,
        bool rollYieldFirst
    ) public {
        uint256 maxDepositable = INITIAL_SUPPLY / 4;
        deposit1 = bound(deposit1, 1 ether, maxDepositable);
        deposit2 = bound(deposit2, 0, maxDepositable - deposit1);
        yieldAccrued = bound(yieldAccrued, 0, 50_000 ether);

        vm.startPrank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, deposit1);
        uint256 mirrorTokenId = mirror.mintPositionWithDeposit(PID, deposit1);

        if (deposit2 > 0) {
            facet.depositToPosition(tokenId, PID, deposit2);
            mirror.depositToPosition(mirrorTokenId, PID, deposit2);
        }

        bytes32 key = nft.getPositionKey(tokenId);
        bytes32 mirrorKey = mirrorNft.getPositionKey(mirrorTokenId);

        facet.setAccruedYield(PID, key, yieldAccrued);
        mirror.setAccruedYield(PID, mirrorKey, yieldAccrued);

        // Apply direct locks/lent principals to constrain withdrawals
        uint256 currentPrincipal = facet.snapshot(PID, key).principal;
        uint256 maxDebt = (currentPrincipal * LTV_BPS) / 10_000;
        lockedDirect = bound(lockedDirect, 0, currentPrincipal);
        lentDirect = bound(lentDirect, 0, currentPrincipal > lockedDirect ? currentPrincipal - lockedDirect : 0);
        if (lentDirect > maxDebt) {
            lentDirect = maxDebt;
        }
        facet.setDirectLocks(key, PID, lockedDirect, lentDirect);
        mirror.setDirectLocks(mirrorKey, PID, lockedDirect, lentDirect);

        if (rollYieldFirst && yieldAccrued > 0) {
            facet.rollYieldToPosition(tokenId, PID);
            mirror.rollYieldToPosition(mirrorTokenId, PID);
            currentPrincipal = facet.snapshot(PID, key).principal; // update after roll
        }

        uint256 available = currentPrincipal > lockedDirect + lentDirect
            ? currentPrincipal - lockedDirect - lentDirect
            : 0;
        // Ensure solvency after withdrawal given direct debt (locked + lent)
        uint256 directDebt = lockedDirect + lentDirect;
        uint256 minPrincipalForDebt = directDebt == 0
            ? 0
            : (directDebt * 10_000 + LTV_BPS - 1) / LTV_BPS; // ceil division
        uint256 maxWithdrawForSolvency = currentPrincipal > minPrincipalForDebt
            ? currentPrincipal - minPrincipalForDebt
            : 0;
        uint256 withdrawCap = available < maxWithdrawForSolvency ? available : maxWithdrawForSolvency;
        withdrawPrincipal = bound(withdrawPrincipal, 0, withdrawCap);
        if (withdrawPrincipal > 0) {
            facet.withdrawFromPosition(tokenId, PID, withdrawPrincipal);
            mirror.withdrawFromPosition(mirrorTokenId, PID, withdrawPrincipal);
        }

        // Attempt cleanup if emptied
        if (facet.snapshot(PID, key).principal == 0) {
            facet.cleanupMembership(tokenId, PID);
            mirror.cleanupMembership(mirrorTokenId, PID);
        }

        vm.stopPrank();

        PositionSnapshot memory snap = facet.snapshot(PID, key);
        PositionSnapshot memory mirrorSnap = mirror.snapshot(PID, mirrorKey);

        assertEq(snap.principal, mirrorSnap.principal, "principal mismatch");
        assertEq(snap.accruedYield, mirrorSnap.accruedYield, "accrued yield mismatch");
        assertEq(snap.totalDeposits, mirrorSnap.totalDeposits, "totalDeposits mismatch");
        assertEq(snap.trackedBalance, mirrorSnap.trackedBalance, "trackedBalance mismatch");
        assertEq(snap.userCount, mirrorSnap.userCount, "userCount mismatch");
        assertEq(snap.feeIndex, mirrorSnap.feeIndex, "feeIndex mismatch");
        assertEq(snap.maintenanceIndex, mirrorSnap.maintenanceIndex, "maintenanceIndex mismatch");
        assertEq(snap.isMember, mirrorSnap.isMember, "membership mismatch");
    }
}

contract PositionMintFeePropertyTest is Test {
    PositionNFT public nft;
    PositionManagementFacetHarness public facet;
    MockERC20 public token;

    address public user = address(0xA11CE);
    address public treasury = address(0xBEEF);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        nft = new PositionNFT();
        facet = new PositionManagementFacetHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, LTV_BPS);
        facet.setTreasury(treasury);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function testFuzz_mintPosition_chargesEthFee(uint96 feeAmount) public {
        feeAmount = uint96(bound(feeAmount, 1, 10 ether));
        facet.setPositionMintFee(address(0), feeAmount);
        vm.deal(user, feeAmount + 1 ether);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(user);
        facet.mintPosition{value: feeAmount}(PID);

        assertEq(treasury.balance - treasuryBefore, feeAmount, "treasury fee mismatch");
    }

    function testFuzz_mintPosition_chargesErc20Fee(uint96 feeAmount) public {
        uint256 maxFee = INITIAL_SUPPLY / 4;
        feeAmount = uint96(bound(feeAmount, 1, maxFee));
        facet.setPositionMintFee(address(token), feeAmount);

        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(user);
        facet.mintPosition(PID);

        assertEq(token.balanceOf(treasury) - treasuryBefore, feeAmount, "erc20 fee mismatch");
    }
}

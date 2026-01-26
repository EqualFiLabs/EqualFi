// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Harness exposing storage setters across rolling, fixed, and direct states.
contract CrossFacetHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(uint256 pid, address underlying, uint16 ltvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = ltvBps;
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
    }

    function seedRolling(uint256 pid, bytes32 positionKey, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.apyBps = 1000;
        loan.active = principalRemaining > 0;
        loan.depositBacked = true;
    }

    function seedFixed(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 principalRemaining) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.borrower = positionKey;
        loan.expiry = uint40(block.timestamp + 30 days);
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = 0;
        p.activeFixedLoanCount[positionKey] = 1;
        p.fixedTermPrincipalRemaining[positionKey] += principalRemaining;
    }

    function setDirectState(bytes32 key, uint256 pid, uint256 locked, uint256 lent, uint256 borrowed) external {
        LibEncumbrance.position(key, pid).directLocked = locked;
        LibEncumbrance.position(key, pid).directLent = lent;
        LibDirectStorage.directStorage().directBorrowedPrincipal[key][pid] = borrowed;
    }

    function totalDebt(uint256 pid, bytes32 key) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateTotalDebt(p, key, pid);
    }

    function poolState(uint256 pid, bytes32 key)
        external
        view
        returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 userCount)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        principal = p.userPrincipal[key];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        userCount = p.userCount;
    }
}

/// @notice Property-like invariant covering debt aggregation across rolling/fixed/direct and solvency under mixed operations.
contract CrossFacetInvariantTest is Test {
    CrossFacetHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal token;

    address internal user = address(0xA11CE);

    uint256 constant PID = 1;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        facet = new CrossFacetHarness();
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), LTV_BPS);

        token.transfer(user, 500_000 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function testFuzz_CrossFacetDebtSolvencyConsistency(
        uint256 depositAmount,
        uint256 rollingBorrow,
        uint256 fixedBorrow,
        uint256 directBorrowed,
        uint256 directLocked,
        uint256 directLent,
        uint256 withdrawAmount
    ) public {
        depositAmount = bound(depositAmount, 50 ether, 300 ether);

        vm.startPrank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, depositAmount);
        bytes32 key = nft.getPositionKey(tokenId);
        vm.stopPrank();

        Types.PoolData storage p = LibAppStorage.s().pools[PID];

        directLocked = bound(directLocked, 0, depositAmount / 2);
        directBorrowed = bound(directBorrowed, 0, depositAmount / 2);
        directLent = bound(directLent, 0, depositAmount / 2);
        facet.setDirectState(key, PID, directLocked, directLent, directBorrowed);

        uint256 availablePrincipal = depositAmount > directLocked + directLent ? depositAmount - directLocked - directLent : 0;
        uint256 maxDebt = (depositAmount * LTV_BPS) / 10_000;
        uint256 maxNewDebt = maxDebt > directBorrowed ? maxDebt - directBorrowed : 0;
        if (availablePrincipal == 0) {
            maxNewDebt = 0;
        }

        rollingBorrow = bound(rollingBorrow, 0, maxNewDebt);
        if (rollingBorrow > 0 && availablePrincipal > 0) {
            facet.seedRolling(PID, key, rollingBorrow);
        }

        uint256 remainingDebtRoom = maxNewDebt > rollingBorrow ? maxNewDebt - rollingBorrow : 0;
        fixedBorrow = bound(fixedBorrow, 0, remainingDebtRoom);
        if (fixedBorrow > 0 && availablePrincipal > 0) {
            facet.seedFixed(PID, key, 1, fixedBorrow);
        }

        uint256 expectedDebt = rollingBorrow + fixedBorrow + directBorrowed;
        assertEq(facet.totalDebt(PID, key), expectedDebt, "totalDebt mismatch");

        // Withdraw up to available principal respecting direct locks/lent
        uint256 currentPrincipal = p.userPrincipal[key];
        uint256 safeWithdrawCap =
            currentPrincipal > directLocked + directLent ? currentPrincipal - directLocked - directLent : 0;
        withdrawAmount = bound(withdrawAmount, 0, safeWithdrawCap);
        if (withdrawAmount > 0) {
            vm.prank(user);
            facet.withdrawFromPosition(tokenId, PID, withdrawAmount);
        }

        uint256 principalAfter = p.userPrincipal[key];
        uint256 debtAfter = facet.totalDebt(PID, key);
        if (debtAfter > 0 && principalAfter > 0) {
            uint256 maxBorrowable = (principalAfter * LTV_BPS) / 10_000;
            assertLe(debtAfter, maxBorrowable, "solvency broken after withdraw");
        }

        (, uint256 totalDeposits,,) = facet.poolState(PID, key);
        assertGt(totalDeposits, 0, "totalDeposits should track principal");
    }
}

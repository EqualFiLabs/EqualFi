// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract LendingLifecycleHarness is LendingFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
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

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
        MockERC20(p.underlying).mint(address(this), principal);
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function userPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return s().pools[pid].userPrincipal[positionKey];
    }

    function rollingLoan(uint256 pid, bytes32 positionKey) external view returns (Types.RollingCreditLoan memory) {
        return s().pools[pid].rollingLoans[positionKey];
    }

    function fixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return s().pools[pid].fixedTermLoans[loanId];
    }
}

contract LendingLifecycleIntegrationTest is Test {
    LendingLifecycleHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal token;

    address internal user = address(0xA11CE);
    uint256 internal constant PID = 1;
    uint16 internal constant LTV_BPS = 8000;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
        nft = new PositionNFT();
        facet = new LendingLifecycleHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, 1200);
        facet.addFixedConfig(PID, 30 days, 1200);

        token.transfer(user, 500_000 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function _seedPosition(uint256 amount) internal returns (uint256 tokenId, bytes32 key) {
        vm.prank(user);
        tokenId = facet.mintFor(user, PID);
        key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, amount);
    }

    function testIntegration_RollingLifecycle_NoInterest() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        uint256 feeIndexStart = facet.feeIndex(PID);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);

        Types.RollingCreditLoan memory loan = facet.rollingLoan(PID, key);
        assertEq(loan.apyBps, 0, "rolling apy forced to zero");
        assertEq(facet.feeIndex(PID), feeIndexStart, "fee index unchanged on open");

        vm.warp(block.timestamp + 30 days);

        uint256 trackedBefore = facet.trackedBalance(PID);
        uint256 remainingBefore = loan.principalRemaining;
        vm.prank(user);
        facet.makePaymentFromPosition(tokenId, PID, 1);
        loan = facet.rollingLoan(PID, key);

        assertEq(loan.principalRemaining, remainingBefore - 1, "tiny payment reduces principal");
        assertEq(facet.trackedBalance(PID), trackedBefore + 1, "tracked balance credits payment");
        assertEq(facet.feeIndex(PID), feeIndexStart, "fee index unchanged after payment");

        trackedBefore = facet.trackedBalance(PID);
        remainingBefore = loan.principalRemaining;
        vm.prank(user);
        facet.makePaymentFromPosition(tokenId, PID, 5 ether);
        loan = facet.rollingLoan(PID, key);

        assertEq(loan.principalRemaining, remainingBefore - 5 ether, "principal reduced by payment");
        assertEq(facet.trackedBalance(PID), trackedBefore + 5 ether, "tracked balance credits payment");
        assertEq(facet.feeIndex(PID), feeIndexStart, "fee index unchanged after second payment");

        uint256 remaining = loan.principalRemaining;
        uint256 userBalanceBefore = token.balanceOf(user);
        trackedBefore = facet.trackedBalance(PID);

        vm.prank(user);
        facet.closeRollingCreditFromPosition(tokenId, PID);

        assertEq(token.balanceOf(user), userBalanceBefore - remaining, "close pays remaining principal only");
        assertEq(facet.trackedBalance(PID), trackedBefore + remaining, "tracked balance credits close");
        loan = facet.rollingLoan(PID, key);
        assertEq(loan.principalRemaining, 0, "loan principal cleared");
        assertFalse(loan.active, "loan inactive");
        assertEq(facet.feeIndex(PID), feeIndexStart, "fee index unchanged after close");
    }

    function testIntegration_FixedLifecycle_NoInterest() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(200 ether);

        uint256 principalBefore = facet.userPrincipal(PID, key);
        uint256 totalDepositsBefore = facet.totalDeposits(PID);

        vm.prank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 40 ether, 0);

        Types.FixedTermLoan memory loan = facet.fixedLoan(PID, loanId);
        assertEq(loan.fullInterest, 0, "fixed fullInterest zero");
        assertFalse(loan.interestRealized, "fixed interestRealized false");
        assertEq(facet.userPrincipal(PID, key), principalBefore, "principal unchanged on open");
        assertEq(facet.totalDeposits(PID), totalDepositsBefore, "total deposits unchanged on open");
        assertEq(facet.trackedBalance(PID), totalDepositsBefore - 40 ether, "tracked balance debited");

        vm.prank(user);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 10 ether);
        loan = facet.fixedLoan(PID, loanId);
        assertEq(loan.principalRemaining, 30 ether, "principal remaining after repay");
        assertEq(facet.trackedBalance(PID), totalDepositsBefore - 30 ether, "tracked balance after repay");

        vm.prank(user);
        facet.repayFixedFromPosition(tokenId, PID, loanId, 30 ether);
        loan = facet.fixedLoan(PID, loanId);
        assertEq(loan.principalRemaining, 0, "principal fully repaid");
        assertTrue(loan.closed, "loan closed");
        assertEq(facet.trackedBalance(PID), totalDepositsBefore, "tracked balance restored");
        assertEq(facet.userPrincipal(PID, key), principalBefore, "principal remains intact");
    }
}

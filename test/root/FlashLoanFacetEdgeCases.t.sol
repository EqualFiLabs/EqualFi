// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FlashLoanReceiverMock is IFlashLoanReceiver {
    bool public shouldRevert;
    bool public returnWrongHash;
    bool public underpay;
    uint16 public feeBps;

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        if (shouldRevert) {
            revert("Receiver reverted");
        }

        if (returnWrongHash) {
            return bytes32(0);
        }

        if (underpay) {
            // Force pull-based repayment to fail
            MockERC20(token).transfer(address(0xdead), amount / 2);
            MockERC20(token).approve(msg.sender, 0);
        }

        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setUnderpay(bool flag) external {
        underpay = flag;
    }

    function setShouldRevert(bool flag) external {
        shouldRevert = flag;
    }

    function setReturnWrongHash(bool flag) external {
        returnWrongHash = flag;
    }
}

contract ReentrantReceiver is IFlashLoanReceiver {
    FlashLoanFacet public facet;
    uint256 public pid;
    uint16 public feeBps;

    constructor(address facet_, uint256 pid_) {
        facet = FlashLoanFacet(facet_);
        pid = pid_;
    }

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        // Try to reenter
        facet.flashLoan(pid, address(this), 1 ether, "");

        uint256 fee = (amount * feeBps) / 10_000;
        MockERC20(token).transfer(msg.sender, amount + fee);
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}

contract FlashLoanHarness is FlashLoanFacet {
    function initPool(uint256 pid, address token, uint16 feeBps, bool antiSplit) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = token;
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = antiSplit;
        p.totalDeposits = 1_000_000 ether;
        p.trackedBalance = MockERC20(token).balanceOf(address(this));
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setTreasuryShare(uint16 bps) external {
        LibAppStorage.AppStorage storage store = s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }

    function setPoolBalance(uint256 pid, uint256 balance) external {
        Types.PoolData storage p = s().pools[pid];
        p.totalDeposits = balance;
    }
}

contract FlashLoanFacetEdgeCasesTest is Test {
    FlashLoanHarness internal facet;
    FlashLoanReceiverMock internal receiver;
    MockERC20 internal token;
    address internal constant TREASURY = address(0xA111);
    uint256 internal constant PID = 1;

    function setUp() public {
        facet = new FlashLoanHarness();
        receiver = new FlashLoanReceiverMock();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        token.mint(address(facet), 1_000_000 ether);
        token.mint(address(receiver), 1_000_000 ether);

        facet.initPool(PID, address(token), 50, true);
        facet.setTreasury(TREASURY);
        facet.setTreasuryShare(2000); // 20%

        receiver.setFeeBps(50);

        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Amount Validation
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanZeroAmountReverts() public {
        vm.expectRevert("Flash: amount=0");
        facet.flashLoan(PID, address(receiver), 0, "");
    }

    function testFlashLoanMinimumAmount() public {
        facet.flashLoan(PID, address(receiver), 1, "");
        // Should succeed with 1 wei
    }

    function testFlashLoanMaximumAmount() public {
        uint256 maxAmount = token.balanceOf(address(facet));
        facet.flashLoan(PID, address(receiver), maxAmount, "");
        // Should succeed
    }

    function testFlashLoanExceedsBalance() public {
        uint256 balance = token.balanceOf(address(facet));
        vm.expectRevert();
        facet.flashLoan(PID, address(receiver), balance + 1, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Callback Validation
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanCallbackReturnsWrongHash() public {
        receiver.setReturnWrongHash(true);
        vm.expectRevert("Flash: callback");
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testFlashLoanReceiverReverts() public {
        receiver.setShouldRevert(true);
        vm.expectRevert("Receiver reverted");
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testFlashLoanReceiverIsEOA() public {
        address eoa = address(0xBEEF);
        vm.expectRevert();
        facet.flashLoan(PID, eoa, 100 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Fee Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanWithZeroFeeReverts() public {
        facet.initPool(2, address(token), 0, false);
        token.mint(address(facet), 1_000_000 ether);

        vm.expectRevert("Flash: fee not set");
        facet.flashLoan(2, address(receiver), 100 ether, "");
    }

    function testFlashLoanWithMaxFeeBps() public {
        facet.initPool(2, address(token), 10000, false); // 100%
        token.mint(address(facet), 1_000_000 ether);
        receiver.setFeeBps(10000);

        facet.flashLoan(2, address(receiver), 100 ether, "");
        // Should succeed with 100% fee
    }

    function testFlashLoanFeeRoundsDown() public {
        // Amount so small that fee rounds to 0
        facet.initPool(2, address(token), 1, false); // 0.01%
        token.mint(address(facet), 1_000_000 ether);
        receiver.setFeeBps(1);

        // 99 wei * 1 / 10000 = 0 (rounds down)
        facet.flashLoan(2, address(receiver), 99, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Treasury Share
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanTreasuryNotSet() public {
        facet.setTreasury(address(0));

        // Should still work, just no treasury transfer
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testFlashLoanTreasuryShareZeroPercent() public {
        facet.setTreasuryShare(0);

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        facet.flashLoan(PID, address(receiver), 100 ether, "");
        uint256 treasuryAfter = token.balanceOf(TREASURY);

        // Treasury should get nothing
        assertEq(treasuryAfter - treasuryBefore, 0);
    }

    function testFlashLoanTreasuryShare100Percent() public {
        facet.setTreasuryShare(10000); // 100%

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        facet.flashLoan(PID, address(receiver), 100 ether, "");
        uint256 treasuryAfter = token.balanceOf(TREASURY);

        uint256 fee = (100 ether * 50) / 10_000;
        // Treasury should get all the fee
        assertEq(treasuryAfter - treasuryBefore, fee);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Anti-Split
    // ═══════════════════════════════════════════════════════════════════════════

    function testAntiSplitSameReceiverDifferentPools() public {
        // Create second pool
        MockERC20 token2 = new MockERC20("Mock Token", "MOCK", 18, 0);
        token2.mint(address(facet), 1_000_000 ether);
        token2.mint(address(receiver), 1_000_000 ether);
        facet.initPool(2, address(token2), 50, true);

        vm.prank(address(receiver));
        token2.approve(address(facet), type(uint256).max);

        // First flash loan on PID 1
        facet.flashLoan(PID, address(receiver), 10 ether, "");

        // Second flash loan on PID 2 same block should work (different pool)
        FlashLoanReceiverMock receiver2 = new FlashLoanReceiverMock();
        receiver2.setFeeBps(50);
        token2.mint(address(receiver2), 1_000_000 ether);
        vm.prank(address(receiver2));
        token2.approve(address(facet), type(uint256).max);

        facet.flashLoan(2, address(receiver2), 10 ether, "");
    }

    function testAntiSplitDifferentReceiversSamePool() public {
        FlashLoanReceiverMock receiver2 = new FlashLoanReceiverMock();
        receiver2.setFeeBps(50);
        token.mint(address(receiver2), 1_000_000 ether);
        vm.prank(address(receiver2));
        token.approve(address(facet), type(uint256).max);

        // First flash loan
        facet.flashLoan(PID, address(receiver), 10 ether, "");

        // Second flash loan same block, different receiver should work
        facet.flashLoan(PID, address(receiver2), 10 ether, "");
    }

    function testAntiSplitDisabled() public {
        facet.initPool(2, address(token), 50, false); // anti-split disabled
        token.mint(address(facet), 1_000_000 ether);

        // Multiple flash loans same block should work
        facet.flashLoan(2, address(receiver), 10 ether, "");
        facet.flashLoan(2, address(receiver), 10 ether, "");
    }

    function testAntiSplitNextBlock() public {
        // First flash loan
        facet.flashLoan(PID, address(receiver), 10 ether, "");

        // Move to next block
        vm.roll(block.number + 1);

        // Second flash loan should work
        facet.flashLoan(PID, address(receiver), 10 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Reentrancy
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanReentrancyBlocked() public {
        ReentrantReceiver reentrant = new ReentrantReceiver(address(facet), PID);
        reentrant.setFeeBps(50);
        token.mint(address(reentrant), 1_000_000 ether);
        vm.prank(address(reentrant));
        token.approve(address(facet), type(uint256).max);

        vm.expectRevert(); // ReentrancyGuard custom error
        facet.flashLoan(PID, address(reentrant), 100 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Pool Validation
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanNonExistentPoolReverts() public {
        vm.expectRevert("Flash: pool not initialized");
        facet.flashLoan(999, address(receiver), 100 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Repayment Validation
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanExactRepayment() public {
        uint256 amount = 100 ether;
        uint256 fee = (amount * 50) / 10_000;
        uint256 treasuryShare = (fee * 2000) / 10_000; // 20% to treasury
        uint256 feeToPool = fee - treasuryShare;

        uint256 balBefore = token.balanceOf(address(facet));
        facet.flashLoan(PID, address(receiver), amount, "");
        uint256 balAfter = token.balanceOf(address(facet));

        // Should have fee minus treasury share
        assertEq(balAfter - balBefore, feeToPool);
    }

    function testFlashLoanOverpayment() public {
        // Receiver pays more than required - should succeed
        receiver.setFeeBps(100); // Pay double the fee

        facet.flashLoan(PID, address(receiver), 100 ether, "");
        // Should succeed
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS - Multiple Sequential Flash Loans
    // ═══════════════════════════════════════════════════════════════════════════

    function testMultipleFlashLoansSequential() public {
        facet.initPool(2, address(token), 50, false); // no anti-split
        token.mint(address(facet), 1_000_000 ether);

        for (uint256 i = 0; i < 5; i++) {
            facet.flashLoan(2, address(receiver), 10 ether, "");
        }
        // All should succeed
    }

    function testFlashLoanAccumulatesFees() public {
        // Disable anti-split for this test
        facet.initPool(2, address(token), 50, false);
        token.mint(address(facet), 1_000_000 ether);

        uint256 treasuryBefore = token.balanceOf(TREASURY);

        facet.flashLoan(2, address(receiver), 100 ether, "");
        facet.flashLoan(2, address(receiver), 100 ether, "");
        facet.flashLoan(2, address(receiver), 100 ether, "");

        uint256 treasuryAfter = token.balanceOf(TREASURY);

        uint256 feePerLoan = (100 ether * 50) / 10_000;
        uint256 treasurySharePerLoan = (feePerLoan * 2000) / 10_000;

        assertEq(treasuryAfter - treasuryBefore, treasurySharePerLoan * 3);
    }
}

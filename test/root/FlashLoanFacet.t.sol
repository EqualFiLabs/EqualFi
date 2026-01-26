// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FlashLoanReceiverMock is IFlashLoanReceiver {
    address public token;
    uint256 public amount;
    bytes public data;
    bool public underpay;
    uint16 public feeBps;

    function onFlashLoan(address initiator, address token_, uint256 amount_, bytes calldata data_)
        external
        override
        returns (bytes32)
    {
        token = token_;
        amount = amount_;
        data = data_;
        if (underpay) {
            // Move away part of the balance so pull-based repayment fails
            MockERC20(token_).transfer(address(0xdead), amount_ / 2);
            MockERC20(token_).approve(msg.sender, 0);
        }
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setUnderpay(bool flag) external {
        underpay = flag;
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

    function feeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }
}

contract FlashLoanFacetTest is Test {
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
        facet.initPool(PID, address(token), 50, true);
        facet.setTreasury(TREASURY);
        receiver.setFeeBps(50);
        token.mint(address(receiver), 1_000_000 ether); // ensure receiver can repay
        token.approve(address(facet), type(uint256).max);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);
    }

    function testFlashLoanChargesFeeAndRepays() public {
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        vm.prank(address(this));
        facet.flashLoan(PID, address(receiver), 100 ether, "hello");

        uint256 fee = (100 ether * 50) / 10_000;
        uint256 treasuryShare = fee / 5;
        assertEq(token.balanceOf(TREASURY) - treasuryBefore, treasuryShare);
        assertEq(receiver.token(), address(token));
        assertEq(receiver.amount(), 100 ether);
        assertEq(receiver.data(), bytes("hello"));
    }

    function testFlashLoanRejectsUnderpayment() public {
        receiver.setUnderpay(true);
        vm.expectRevert(); // allowance/balance shortfall should revert
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testAntiSplitBlocksSameBlockMultiple() public {
        vm.prank(address(this));
        facet.flashLoan(PID, address(receiver), 10 ether, "");
        vm.expectRevert("Flash: split block");
        vm.prank(address(this));
        facet.flashLoan(PID, address(receiver), 5 ether, "");
    }

    function testAntiSplitAllowsNextBlock() public {
        facet.flashLoan(PID, address(receiver), 10 ether, "");
        vm.roll(block.number + 1);
        facet.flashLoan(PID, address(receiver), 5 ether, "");
    }

    function testAntiSplitDisabledAllowsSameBlock() public {
        uint256 newPid = 2;
        facet.initPool(newPid, address(token), 50, false); // anti-split disabled
        facet.flashLoan(newPid, address(receiver), 10 ether, "");
        facet.flashLoan(newPid, address(receiver), 5 ether, "");
    }

    function testDocExampleFlashLoanScenario() public {
        // Doc example: 0.3% fee, anti-split enabled, treasury gets 20% of fee
        uint256 pid = 3;
        facet.initPool(pid, address(token), 30, true); // 0.3%
        facet.setTreasuryShare(2000); // 20%
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 trackedBefore = facet.trackedBalance(pid);
        uint256 indexBefore = facet.feeIndex(pid);
        uint256 totalDeposits = facet.totalDeposits(pid);

        uint256 amount = 100 ether;
        uint256 fee = (amount * 30) / 10_000; // 0.3 ether
        uint256 treasuryShare = (fee * 2000) / 10_000; // 20% of fee
        uint256 indexAccrual = fee - treasuryShare;

        facet.flashLoan(pid, address(receiver), amount, "doc");

        assertEq(token.balanceOf(TREASURY) - treasuryBefore, treasuryShare, "treasury cut from fee");
        assertEq(facet.trackedBalance(pid) - trackedBefore, indexAccrual, "pool tracked balance accrues index share");
        uint256 expectedIndexDelta = (indexAccrual * 1e18) / totalDeposits;
        assertEq(facet.feeIndex(pid) - indexBefore, expectedIndexDelta, "fee index accrual proportional to deposits");

        vm.expectRevert("Flash: split block");
        facet.flashLoan(pid, address(receiver), 1 ether, "");
    }
}

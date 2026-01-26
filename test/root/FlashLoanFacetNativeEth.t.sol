// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {UnexpectedMsgValue} from "../../src/libraries/Errors.sol";

contract NativeFlashLoanReceiver is IFlashLoanReceiver {
    uint16 public feeBps;
    bool public underpay;
    address public lastToken;
    uint256 public lastAmount;
    bytes public lastData;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setUnderpay(bool flag) external {
        underpay = flag;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        lastToken = token;
        lastAmount = amount;
        lastData = data;
        if (token == address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            uint256 repay = underpay ? amount : amount + fee;
            (bool success,) = msg.sender.call{value: repay}("");
            require(success, "repay failed");
        }
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    receive() external payable {}
}

contract FlashLoanNativeHarness is FlashLoanFacet {
    function initNativePool(uint256 pid, uint16 feeBps, bool antiSplit, uint256 trackedBalance, uint256 deposits)
        external
    {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = address(0);
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = antiSplit;
        p.trackedBalance = trackedBalance;
        p.totalDeposits = deposits;
    }

    function setNativeTrackedTotal(uint256 value) external {
        LibAppStorage.s().nativeTrackedTotal = value;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    receive() external payable {}
}

contract FlashLoanFacetNativeEthTest is Test {
    FlashLoanNativeHarness internal facet;
    NativeFlashLoanReceiver internal receiver;
    uint256 internal constant PID = 1;

    function setUp() public {
        facet = new FlashLoanNativeHarness();
        receiver = new NativeFlashLoanReceiver();
    }

    function testFlashLoanNativeRoundTrip() public {
        uint16 feeBps = 100; // 1%
        uint256 amount = 100 ether;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 deposits = 100 ether;

        facet.initNativePool(PID, feeBps, false, amount, deposits);
        facet.setNativeTrackedTotal(amount);
        vm.deal(address(facet), amount);
        vm.deal(address(receiver), fee);
        receiver.setFeeBps(feeBps);

        uint256 trackedBefore = facet.trackedBalance(PID);
        uint256 feeIndexBefore = facet.feeIndex(PID);
        uint256 nativeTrackedBefore = facet.nativeTrackedTotal();

        facet.flashLoan(PID, address(receiver), amount, "native");

        assertEq(receiver.lastToken(), address(0));
        assertEq(receiver.lastAmount(), amount);
        assertEq(receiver.lastData(), bytes("native"));

        assertEq(facet.trackedBalance(PID), trackedBefore + fee, "trackedBalance accrues fee");
        assertEq(facet.nativeTrackedTotal(), nativeTrackedBefore + fee, "nativeTrackedTotal accrues fee");

        uint256 expectedDelta = (fee * 1e18) / deposits;
        assertEq(facet.feeIndex(PID), feeIndexBefore + expectedDelta, "fee index accrues");
    }

    function testFlashLoanNativeUnderfundedReverts() public {
        uint16 feeBps = 100; // 1%
        uint256 amount = 10 ether;

        facet.initNativePool(PID, feeBps, false, amount, amount);
        facet.setNativeTrackedTotal(amount);
        vm.deal(address(facet), amount);
        receiver.setFeeBps(feeBps);
        receiver.setUnderpay(true);

        vm.expectRevert(bytes("Flash: not repaid"));
        facet.flashLoan(PID, address(receiver), amount, "");
    }

    function testFlashLoanNativeRejectsMsgValue() public {
        facet.initNativePool(PID, 100, false, 1 ether, 1 ether);
        facet.setNativeTrackedTotal(1 ether);
        vm.deal(address(facet), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1));
        facet.flashLoan{value: 1}(PID, address(receiver), 1 ether, "");
    }
}

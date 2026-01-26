// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibCurrency} from "../../src/libraries/LibCurrency.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {InsufficientPoolLiquidity, NativeTransferFailed, UnexpectedMsgValue} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";

contract LibCurrencyHarness {
    function pullNative(uint256 amount) external payable returns (uint256) {
        return LibCurrency.pull(address(0), msg.sender, amount);
    }

    function pullToken(address token, address from, uint256 amount) external returns (uint256) {
        return LibCurrency.pull(token, from, amount);
    }

    function doTransfer(address token, address to, uint256 amount) external {
        LibCurrency.transfer(token, to, amount);
    }

    function balanceOfSelf(address token) external view returns (uint256) {
        return LibCurrency.balanceOfSelf(token);
    }

    function assertZero() external payable {
        LibCurrency.assertZeroMsgValue();
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function setNativeTrackedTotal(uint256 value) external {
        LibAppStorage.s().nativeTrackedTotal = value;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

contract LibCurrencyTest is Test {
    LibCurrencyHarness internal harness;
    address internal user = address(0xA11CE);
    address internal receiver = address(0xBEEF);

    function setUp() public {
        harness = new LibCurrencyHarness();
    }

    /// Feature: native-eth-support, Property 1: LibCurrency Branching Correctness
    function testFuzz_pullNativeRejectsMismatchedMsgValue(uint256 value) public {
        value = bound(value, 1, 100 ether);
        uint256 amount = value + 1;
        vm.deal(address(this), value);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, value));
        harness.pullNative{value: value}(amount);
    }

    function testFuzz_pullNativeAcceptsExactMsgValue(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), amount);

        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 balanceBefore = address(harness).balance;
        uint256 received = harness.pullNative{value: amount}(amount);
        assertEq(received, amount);
        assertEq(harness.nativeTrackedTotal(), trackedBefore + amount);
        assertEq(address(harness).balance, balanceBefore + amount);
    }

    /// Feature: native-eth-support, Property 1: LibCurrency Branching Correctness
    function testFuzz_pullNativeEnforcesAvailable(uint256 balance, uint256 tracked, uint256 extra) public {
        balance = bound(balance, 0, 100 ether);
        tracked = bound(tracked, 0, balance);
        vm.deal(address(harness), balance);
        harness.setNativeTrackedTotal(tracked);

        uint256 available = balance - tracked;
        extra = bound(extra, 1, 100 ether);
        uint256 amount = available + extra;

        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolLiquidity.selector, amount, available));
        harness.pullNative(amount);
    }

    /// Feature: native-eth-support, Property 1: LibCurrency Branching Correctness
    function testFuzz_pullNativeUpdatesTracked(uint256 balance, uint256 tracked, uint256 amount) public {
        balance = bound(balance, 0, 100 ether);
        tracked = bound(tracked, 0, balance);
        vm.deal(address(harness), balance);
        harness.setNativeTrackedTotal(tracked);

        uint256 available = balance - tracked;
        amount = bound(amount, 0, available);

        uint256 beforeTracked = harness.nativeTrackedTotal();
        uint256 received = harness.pullNative(amount);
        assertEq(received, amount);
        assertEq(harness.nativeTrackedTotal(), beforeTracked + amount);
        assertEq(address(harness).balance, balance);
    }

    /// Feature: native-eth-support, Property 6: Fee-on-Transfer Token Handling
    function testFuzz_pullFeeOnTransferReturnsDelta(uint256 amount, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 10_000));
        amount = bound(amount, 1, 1e24);

        FeeOnTransferERC20 token = new FeeOnTransferERC20("FeeToken", "FEE", 18, 0, feeBps, receiver);
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(harness), amount);
        uint256 received = harness.pullToken(address(token), user, amount);
        vm.stopPrank();

        uint256 fee = (amount * feeBps) / 10_000;
        uint256 expected = amount - fee;
        assertEq(received, expected);
        assertEq(token.balanceOf(address(harness)), expected);
    }

    function test_assertZeroMsgValue_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1));
        harness.assertZero{value: 1}();
    }

    function test_balanceOfSelf_nativeAndErc20() public {
        vm.deal(address(harness), 5 ether);
        assertEq(harness.balanceOfSelf(address(0)), 5 ether);

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        token.mint(address(harness), 200 ether);
        assertEq(harness.balanceOfSelf(address(token)), 200 ether);
    }

    function test_transfer_native_success() public {
        vm.deal(address(harness), 1 ether);
        harness.doTransfer(address(0), receiver, 1 ether);
        assertEq(receiver.balance, 1 ether);
    }

    function test_transfer_native_revertsOnFail() public {
        RevertingReceiver sink = new RevertingReceiver();
        vm.deal(address(harness), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NativeTransferFailed.selector, address(sink), 1 ether));
        harness.doTransfer(address(0), address(sink), 1 ether);
    }

    function test_transfer_erc20() public {
        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        token.mint(address(harness), 50 ether);
        harness.doTransfer(address(token), receiver, 20 ether);
        assertEq(token.balanceOf(receiver), 20 ether);
        assertEq(token.balanceOf(address(harness)), 30 ether);
    }

    function test_pull_erc20_returnsReceived() public {
        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        token.mint(user, 100 ether);

        vm.startPrank(user);
        token.approve(address(harness), 80 ether);
        uint256 received = harness.pullToken(address(token), user, 80 ether);
        vm.stopPrank();

        assertEq(received, 80 ether);
        assertEq(token.balanceOf(address(harness)), 80 ether);
    }

    function test_pull_native_returnsAmount() public {
        vm.deal(address(harness), 10 ether);
        harness.setNativeTrackedTotal(2 ether);

        uint256 received = harness.pullNative(3 ether);
        assertEq(received, 3 ether);
        assertEq(harness.nativeTrackedTotal(), 5 ether);
        assertEq(address(harness).balance, 10 ether);
    }
}

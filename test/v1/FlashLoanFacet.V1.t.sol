// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LocalFlashMockERC20V1 is ERC20 {
    constructor() ERC20("FlashToken", "FLASH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FlashLoanReceiverV1 is IFlashLoanReceiver {
    bool public wrongHash;
    bool public forceUnderpay;
    address public seenToken;
    uint256 public seenAmount;
    bytes public seenData;

    function onFlashLoan(address, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32)
    {
        seenToken = token;
        seenAmount = amount;
        seenData = data;

        if (forceUnderpay) {
            LocalFlashMockERC20V1(token).transfer(address(0xDEAD), amount / 2);
            LocalFlashMockERC20V1(token).approve(msg.sender, 0);
        }

        if (wrongHash) {
            return bytes32(0);
        }

        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    function setWrongHash(bool flag) external {
        wrongHash = flag;
    }

    function setForceUnderpay(bool flag) external {
        forceUnderpay = flag;
    }
}

contract FlashLoanV1Harness is FlashLoanFacet {
    function seedPool(uint256 pid, address underlying, uint16 feeBps, bool antiSplit, uint256 liquidity) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = antiSplit;
        p.totalDeposits = liquidity;
        p.trackedBalance = liquidity;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }
}

contract FlashLoanFacetV1Test is Test {
    uint256 internal constant PID = 1;

    FlashLoanV1Harness internal harness;
    FlashLoanReceiverV1 internal receiver;
    LocalFlashMockERC20V1 internal token;

    function setUp() public {
        harness = new FlashLoanV1Harness();
        receiver = new FlashLoanReceiverV1();
        token = new LocalFlashMockERC20V1();

        token.mint(address(harness), 1_000_000 ether);
        token.mint(address(receiver), 1_000_000 ether);

        harness.seedPool(PID, address(token), 50, true, 1_000_000 ether);

        vm.prank(address(receiver));
        token.approve(address(harness), type(uint256).max);
    }

    function test_flashLoan_success() public {
        uint256 amount = 100 ether;
        uint256 fee = (amount * 50) / 10_000;
        uint256 balanceBefore = token.balanceOf(address(harness));

        harness.flashLoan(PID, address(receiver), amount, "hello", harness.previewFlashLoanRepayment(PID, amount));

        assertEq(receiver.seenToken(), address(token));
        assertEq(receiver.seenAmount(), amount);
        assertEq(receiver.seenData(), bytes("hello"));
        assertEq(token.balanceOf(address(harness)), balanceBefore + fee);
        assertEq(harness.trackedBalance(PID), 1_000_000 ether + fee);
    }

    function test_flashLoan_wrongCallbackHashReverts() public {
        receiver.setWrongHash(true);
        uint256 repayment = harness.previewFlashLoanRepayment(PID, 1 ether);
        vm.expectRevert("Flash: callback");
        harness.flashLoan(PID, address(receiver), 1 ether, "", repayment);
    }

    function test_flashLoan_underpayReverts() public {
        receiver.setForceUnderpay(true);
        uint256 repayment = harness.previewFlashLoanRepayment(PID, 1 ether);
        vm.expectRevert();
        harness.flashLoan(PID, address(receiver), 1 ether, "", repayment);
    }

    function test_flashLoan_antiSplitSameBlockReverts() public {
        harness.flashLoan(PID, address(receiver), 1 ether, "", harness.previewFlashLoanRepayment(PID, 1 ether));

        uint256 repayment = harness.previewFlashLoanRepayment(PID, 1 ether);
        vm.expectRevert("Flash: split block");
        harness.flashLoan(PID, address(receiver), 1 ether, "", repayment);
    }
}

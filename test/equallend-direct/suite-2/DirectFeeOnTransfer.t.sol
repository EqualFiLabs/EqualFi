// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeOnTransferERC20} from "../../../src/mocks/FeeOnTransferERC20.sol";
import {LibCurrency} from "../../../src/libraries/LibCurrency.sol";

/// @notice Minimal harness that exercises LibCurrency.pullAtLeast with a fee-on-transfer token.
/// The production Direct repay path uses LibCurrency.pullAtLeast to pull at least `principal`
/// from the borrower, given a `maxPayment` that must be grossed up for FoT.
contract LibCurrencyFoTHarness {
    using LibCurrency for address;

    /// @dev Mimic the Direct repay pull: pull at least `minAmount` from `from`,
    ///      allowing the caller to specify a larger `maxAmount` to account for fees.
    function pullAtLeastFoT(
        address token,
        address from,
        uint256 minAmount,
        uint256 maxAmount
    ) external returns (uint256 received) {
        // Directly delegate to the library so semantics match production.
        // For ERC20 (non-native) this calls SafeERC20.safeTransferFrom and checks
        // that the difference in balance is >= minAmount, reverting otherwise.
        received = LibCurrency.pullAtLeast(token, from, minAmount, maxAmount);
    }
}

contract DirectFeeOnTransferTest is Test {
    LibCurrencyFoTHarness internal harness;
    FeeOnTransferERC20 internal token;

    address internal borrower = address(0xB0B);
    address internal feeSink = address(0xFEE);

    function setUp() public {
        harness = new LibCurrencyFoTHarness();

        // 5% fee-on-transfer token, initial supply minted to this test contract.
        token = new FeeOnTransferERC20("Fee Token", "FEE", 18, 1_000_000 ether, 500, feeSink);

        // Fund borrower and approve harness.
        token.transfer(borrower, 200 ether);
        vm.prank(borrower);
        token.approve(address(harness), type(uint256).max);
    }

    function _grossWithFee(uint256 netAmount) internal view returns (uint256) {
        uint256 feeBps = token.feeBps();
        // Compute gross so that, after a fee of `feeBps`, at least `netAmount` is received.
        return Math.mulDiv(netAmount, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function test_directRepay_acceptsFoTWithGrossedMax() public {
        uint256 principal = 50 ether;
        uint256 gross = _grossWithFee(principal);

        uint256 sinkBefore = token.balanceOf(feeSink);

        // Simulate the repay path: LibCurrency.pullAtLeast pulls from the borrower
        // with maxAmount = gross and requires that the net received >= principal.
        vm.prank(borrower);
        uint256 received = harness.pullAtLeastFoT(address(token), borrower, principal, gross);

        // Net received by the harness should be at least the principal.
        assertGe(received, principal, "net payment covers principal");
        // Fee sink should have increased balance due to FeeOnTransfer mechanics.
        assertGt(token.balanceOf(feeSink), sinkBefore, "fee charged");
    }
}

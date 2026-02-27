// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DerivativeTypes} from "src/libraries/DerivativeTypes.sol";
import {LibAuctionSwap} from "src/libraries/LibAuctionSwap.sol";

contract LibAuctionSwapHarness {
    function computeSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps
    ) external pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return LibAuctionSwap.computeSwap(feeAsset, reserveIn, reserveOut, amountIn, feeBps);
    }

    function computeSwapByInvariant(
        DerivativeTypes.InvariantMode invariantMode,
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut
    ) external pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return LibAuctionSwap.computeSwapByInvariant(
            invariantMode, feeAsset, reserveIn, reserveOut, amountIn, feeBps, decimalsIn, decimalsOut
        );
    }

    function computeStableSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut,
        uint256 maxIterations
    ) external pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return LibAuctionSwap.computeStableSwap(
            feeAsset, reserveIn, reserveOut, amountIn, feeBps, decimalsIn, decimalsOut, maxIterations
        );
    }
}

contract LibAuctionSwapTest is Test {
    LibAuctionSwapHarness internal h;

    function setUp() public {
        h = new LibAuctionSwapHarness();
    }

    function test_stableSwap_handlesDecimalsMismatch_6To18() public {
        uint256 reserveIn = 1_000_000e6;
        uint256 reserveOut = 1_000_000e18;
        uint256 amountIn = 1e6;

        (uint256 rawOut,, uint256 outToRecipient) = h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            reserveIn,
            reserveOut,
            amountIn,
            0,
            6,
            18
        );

        assertGt(rawOut, 0, "raw out");
        assertGt(outToRecipient, 0, "recipient out");
        assertApproxEqAbs(outToRecipient, 1e18, 2e12, "1 USDC ~= 1 tokenOut");
    }

    function test_stableSwap_handlesDecimalsMismatch_18To6() public {
        uint256 reserveIn = 1_000_000e18;
        uint256 reserveOut = 1_000_000e6;
        uint256 amountIn = 1e18;

        (uint256 rawOut,, uint256 outToRecipient) = h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            reserveIn,
            reserveOut,
            amountIn,
            0,
            18,
            6
        );

        assertGt(rawOut, 0, "raw out");
        assertGt(outToRecipient, 0, "recipient out");
        assertApproxEqAbs(outToRecipient, 1e6, 2, "1 tokenIn ~= 1 USDC");
    }

    function test_stableSwap_lowReserves_returnsBoundedOut() public {
        uint256 reserveIn = 5e18;
        uint256 reserveOut = 5e18;
        uint256 amountIn = 1e15;

        (uint256 rawOut,, uint256 outToRecipient) = h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            reserveIn,
            reserveOut,
            amountIn,
            30,
            18,
            18
        );

        assertGt(rawOut, 0, "raw out");
        assertGt(outToRecipient, 0, "recipient out");
        assertLt(outToRecipient, reserveOut, "cannot drain reserve");
    }

    function test_stableSwap_revertsOnZeroReserveIn() public {
        vm.expectRevert(LibAuctionSwap.LibAuctionSwap_InvalidStableInput.selector);
        h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            0,
            1e18,
            1e18,
            0,
            18,
            18
        );
    }

    function test_stableSwap_revertsOnZeroReserveOut() public {
        vm.expectRevert(LibAuctionSwap.LibAuctionSwap_InvalidStableInput.selector);
        h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            1e18,
            0,
            1e18,
            0,
            18,
            18
        );
    }

    function test_stableSwap_revertsOnZeroAmountIn() public {
        vm.expectRevert(LibAuctionSwap.LibAuctionSwap_InvalidStableInput.selector);
        h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            1e18,
            1e18,
            0,
            0,
            18,
            18
        );
    }

    function test_stableSwap_revertsOnUnsupportedDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(LibAuctionSwap.LibAuctionSwap_UnsupportedDecimals.selector, uint8(78)));
        h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Stable,
            DerivativeTypes.FeeAsset.TokenIn,
            1e18,
            1e18,
            1e18,
            0,
            96,
            18
        );
    }

    function test_stableSwap_revertsOnNonConvergence() public {
        vm.expectRevert(LibAuctionSwap.LibAuctionSwap_StableNonConvergence.selector);
        h.computeStableSwap(DerivativeTypes.FeeAsset.TokenIn, 10_000e18, 10_000e18, 1e18, 0, 18, 18, 0);
    }

    function test_volatilePath_unchangedViaModeAwareEntry() public {
        uint256 reserveIn = 1000e18;
        uint256 reserveOut = 500e18;
        uint256 amountIn = 10e18;
        uint16 feeBps = 30;

        (uint256 rawOutLegacy, uint256 feeLegacy, uint256 outLegacy) =
            h.computeSwap(DerivativeTypes.FeeAsset.TokenIn, reserveIn, reserveOut, amountIn, feeBps);
        (uint256 rawOutMode, uint256 feeMode, uint256 outMode) = h.computeSwapByInvariant(
            DerivativeTypes.InvariantMode.Volatile,
            DerivativeTypes.FeeAsset.TokenIn,
            reserveIn,
            reserveOut,
            amountIn,
            feeBps,
            18,
            18
        );

        assertEq(rawOutMode, rawOutLegacy, "raw out");
        assertEq(feeMode, feeLegacy, "fee amount");
        assertEq(outMode, outLegacy, "out to recipient");
    }

    function testFuzz_stableDeterministicBoundedSolve(
        uint96 reserveInSeed,
        uint96 reserveOutSeed,
        uint96 amountInSeed,
        uint16 feeBpsSeed
    ) public {
        uint256 reserveIn = bound(uint256(reserveInSeed), 1e18, 10_000_000e18);
        uint256 reserveOut = bound(uint256(reserveOutSeed), 1e18, 10_000_000e18);
        uint256 amountIn = bound(uint256(amountInSeed), 1e12, reserveIn / 20);
        uint16 feeBps = uint16(bound(uint256(feeBpsSeed), 0, 1000));

        (uint256 rawOut1, uint256 feeAmount1, uint256 out1) =
            h.computeStableSwap(DerivativeTypes.FeeAsset.TokenIn, reserveIn, reserveOut, amountIn, feeBps, 18, 18, 255);
        (uint256 rawOut2, uint256 feeAmount2, uint256 out2) =
            h.computeStableSwap(DerivativeTypes.FeeAsset.TokenIn, reserveIn, reserveOut, amountIn, feeBps, 18, 18, 255);

        assertEq(rawOut1, rawOut2, "deterministic raw out");
        assertEq(feeAmount1, feeAmount2, "deterministic fee");
        assertEq(out1, out2, "deterministic out");
        assertLe(out1, reserveOut, "bounded by reserve");
    }
}

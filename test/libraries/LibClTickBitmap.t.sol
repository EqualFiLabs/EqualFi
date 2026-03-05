// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClTickBitmap} from "src/libraries/LibClTickBitmap.sol";

contract LibClTickBitmapHarness {
    function flipTick(uint256 auctionId, int24 tick, int24 tickSpacing) external {
        LibClTickBitmap.flipTick(auctionId, tick, tickSpacing);
    }

    function nextInitializedTickWithinOneWord(uint256 auctionId, int24 tick, int24 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return LibClTickBitmap.nextInitializedTickWithinOneWord(auctionId, tick, tickSpacing, lte);
    }

    function setWord(uint256 auctionId, int16 wordPos, uint256 word) external {
        LibClTickBitmap.s().tickBitmaps[auctionId][wordPos] = word;
    }

    function getWord(uint256 auctionId, int16 wordPos) external view returns (uint256) {
        return LibClTickBitmap.s().tickBitmaps[auctionId][wordPos];
    }
}

contract LibClTickBitmapTest is Test {
    uint256 internal constant AUCTION_ID = 1;

    LibClTickBitmapHarness internal h;

    function setUp() public {
        h = new LibClTickBitmapHarness();
    }

    /// @notice Feature: cl-community-auction, Property 19: Tick bitmap traversal correctness (lte)
    function testFuzz_tickBitmapTraversalCorrectness_lte(uint256 word, uint16 spacingSeed, int16 wordPosSeed, uint8 bitPos)
        public
    {
        int24 tickSpacing = int24(uint24(bound(uint256(spacingSeed), 1, 250)));
        int16 wordPos = int16(bound(int256(wordPosSeed), -80, 80));

        h.setWord(AUCTION_ID, wordPos, word);

        int24 compressed = int24(int256(wordPos) * 256 + int256(uint256(bitPos)));
        int24 tick = compressed * tickSpacing;

        (int24 next, bool initialized) = h.nextInitializedTickWithinOneWord(AUCTION_ID, tick, tickSpacing, true);

        uint256 mask = bitPos == type(uint8).max ? type(uint256).max : (uint256(1) << (uint256(bitPos) + 1)) - 1;
        uint256 masked = word & mask;
        bool expectedInitialized = masked != 0;

        int24 expectedCompressed = expectedInitialized
            ? compressed - int24(uint24(bitPos - _mostSignificantBit(masked)))
            : compressed - int24(uint24(bitPos));

        assertEq(initialized, expectedInitialized);
        assertEq(next, expectedCompressed * tickSpacing);
    }

    /// @notice Feature: cl-community-auction, Property 19: Tick bitmap traversal correctness (gt)
    function testFuzz_tickBitmapTraversalCorrectness_gt(
        uint256 currentWord,
        uint256 nextWord,
        uint16 spacingSeed,
        int16 wordPosSeed,
        uint8 bitPos
    ) public {
        int24 tickSpacing = int24(uint24(bound(uint256(spacingSeed), 1, 250)));
        int16 wordPos = int16(bound(int256(wordPosSeed), -80, 80));

        h.setWord(AUCTION_ID, wordPos, currentWord);
        h.setWord(AUCTION_ID, wordPos + 1, nextWord);

        int24 compressed = int24(int256(wordPos) * 256 + int256(uint256(bitPos)));
        int24 tick = compressed * tickSpacing;

        (int24 next, bool initialized) = h.nextInitializedTickWithinOneWord(AUCTION_ID, tick, tickSpacing, false);

        uint8 searchBitPos = bitPos == type(uint8).max ? uint8(0) : bitPos + 1;
        uint256 searchWord = bitPos == type(uint8).max ? nextWord : currentWord;

        uint256 mask = ~((uint256(1) << searchBitPos) - 1);
        uint256 masked = searchWord & mask;
        bool expectedInitialized = masked != 0;

        int24 expectedCompressed = expectedInitialized
            ? compressed + 1 + int24(uint24(_leastSignificantBit(masked) - searchBitPos))
            : compressed + 1 + int24(uint24(type(uint8).max - searchBitPos));

        assertEq(initialized, expectedInitialized);
        assertEq(next, expectedCompressed * tickSpacing);
    }

    function test_flipTick_togglesBitAndValidatesInputs() public {
        h.flipTick(AUCTION_ID, 20, 10);
        assertEq(h.getWord(AUCTION_ID, 0), uint256(1) << 2);

        h.flipTick(AUCTION_ID, 20, 10);
        assertEq(h.getWord(AUCTION_ID, 0), 0);

        vm.expectRevert(abi.encodeWithSelector(LibClTickBitmap.LibClTickBitmap_InvalidTickSpacing.selector, int24(0)));
        h.flipTick(AUCTION_ID, 20, 0);

        vm.expectRevert(abi.encodeWithSelector(LibClTickBitmap.LibClTickBitmap_UnalignedTick.selector, int24(21), int24(10)));
        h.flipTick(AUCTION_ID, 21, 10);
    }

    function test_emptyBitmap_returnsWordBoundaries() public {
        (int24 nextLte, bool initLte) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 500, 1, true);
        assertEq(nextLte, 256);
        assertFalse(initLte);

        (int24 nextGt, bool initGt) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 500, 1, false);
        assertEq(nextGt, 511);
        assertFalse(initGt);
    }

    function test_singleTick_behavior() public {
        h.flipTick(AUCTION_ID, 120, 1);

        (int24 nextLteAtTick, bool initLteAtTick) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 120, 1, true);
        assertEq(nextLteAtTick, 120);
        assertTrue(initLteAtTick);

        (int24 nextLteAfterTick, bool initLteAfterTick) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 130, 1, true);
        assertEq(nextLteAfterTick, 120);
        assertTrue(initLteAfterTick);

        (int24 nextGtBeforeTick, bool initGtBeforeTick) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 100, 1, false);
        assertEq(nextGtBeforeTick, 120);
        assertTrue(initGtBeforeTick);

        (int24 nextGtAtTick, bool initGtAtTick) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 120, 1, false);
        assertEq(nextGtAtTick, 255);
        assertFalse(initGtAtTick);
    }

    function test_wordBoundaryCrossing_gtIntoNextWord() public {
        h.flipTick(AUCTION_ID, 256, 1);

        (int24 nextGt, bool initialized) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 255, 1, false);
        assertEq(nextGt, 256);
        assertTrue(initialized);
    }

    function test_allTicksInitializedInWord() public {
        h.setWord(AUCTION_ID, 0, type(uint256).max);

        (int24 nextLte, bool initLte) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 100, 1, true);
        assertEq(nextLte, 100);
        assertTrue(initLte);

        (int24 nextGt, bool initGt) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 100, 1, false);
        assertEq(nextGt, 101);
        assertTrue(initGt);

        (int24 nextGtWordEnd, bool initGtWordEnd) = h.nextInitializedTickWithinOneWord(AUCTION_ID, 255, 1, false);
        assertEq(nextGtWordEnd, 511);
        assertFalse(initGtWordEnd);
    }

    function test_negativeTick_roundingTowardNegativeInfinity() public {
        h.flipTick(AUCTION_ID, -20, 10);

        (int24 nextLte, bool initLte) = h.nextInitializedTickWithinOneWord(AUCTION_ID, -11, 10, true);
        assertEq(nextLte, -20);
        assertTrue(initLte);

        (int24 nextGt, bool initGt) = h.nextInitializedTickWithinOneWord(AUCTION_ID, -11, 10, false);
        assertEq(nextGt, -10);
        assertFalse(initGt);
    }

    function _mostSignificantBit(uint256 x) private pure returns (uint8 r) {
        while (x > 1) {
            x >>= 1;
            r++;
        }
    }

    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        while (x & 1 == 0) {
            x >>= 1;
            r++;
        }
    }
}

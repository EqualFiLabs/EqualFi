// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Packed initialized-tick bitmap indexed per auction.
/// @dev Mirrors Uniswap v3 bitmap traversal semantics with auction-scoped storage.
library LibClTickBitmap {
    bytes32 internal constant STORAGE_POSITION = keccak256("equal.cl.tick.bitmap.storage");

    struct ClTickBitmapStorage {
        mapping(uint256 => mapping(int16 => uint256)) tickBitmaps;
    }

    error LibClTickBitmap_InvalidTickSpacing(int24 tickSpacing);
    error LibClTickBitmap_UnalignedTick(int24 tick, int24 tickSpacing);

    function s() internal pure returns (ClTickBitmapStorage storage bs) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            bs.slot := position
        }
    }

    function flipTick(uint256 auctionId, int24 tick, int24 tickSpacing) internal {
        if (tickSpacing <= 0) revert LibClTickBitmap_InvalidTickSpacing(tickSpacing);
        if (tick % tickSpacing != 0) revert LibClTickBitmap_UnalignedTick(tick, tickSpacing);

        (int16 wordPos, uint8 bitPos) = _position(tick / tickSpacing);
        uint256 mask = uint256(1) << bitPos;
        s().tickBitmaps[auctionId][wordPos] ^= mask;
    }

    function nextInitializedTickWithinOneWord(uint256 auctionId, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        if (tickSpacing <= 0) revert LibClTickBitmap_InvalidTickSpacing(tickSpacing);

        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }

        if (lte) {
            (int16 wordPos, uint8 bitPos) = _position(compressed);
            uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
            uint256 masked = s().tickBitmaps[auctionId][wordPos] & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - _mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
            uint256 mask = ~((uint256(1) << bitPos) - 1);
            uint256 masked = s().tickBitmaps[auctionId][wordPos] & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24(_leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }

    function getWord(uint256 auctionId, int16 wordPos) internal view returns (uint256) {
        return s().tickBitmaps[auctionId][wordPos];
    }

    function _position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);

        int24 mod = tick % 256;
        if (mod < 0) {
            mod += 256;
        }
        bitPos = uint8(uint24(mod));
    }

    function _mostSignificantBit(uint256 x) private pure returns (uint8 r) {
        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) {
            r += 1;
        }
    }

    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        r = 255;

        if (x & type(uint128).max > 0) {
            r -= 128;
        } else {
            x >>= 128;
        }
        if (x & type(uint64).max > 0) {
            r -= 64;
        } else {
            x >>= 64;
        }
        if (x & type(uint32).max > 0) {
            r -= 32;
        } else {
            x >>= 32;
        }
        if (x & type(uint16).max > 0) {
            r -= 16;
        } else {
            x >>= 16;
        }
        if (x & type(uint8).max > 0) {
            r -= 8;
        } else {
            x >>= 8;
        }
        if (x & 0xF > 0) {
            r -= 4;
        } else {
            x >>= 4;
        }
        if (x & 0x3 > 0) {
            r -= 2;
        } else {
            x >>= 2;
        }
        if (x & 0x1 > 0) {
            r -= 1;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";

contract LibIlmSharesMathHarness {
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return LibIlmSharesMath.toSharesDown(assets, totalAssets, totalShares);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return LibIlmSharesMath.toSharesUp(assets, totalAssets, totalShares);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return LibIlmSharesMath.toAssetsDown(shares, totalAssets, totalShares);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return LibIlmSharesMath.toAssetsUp(shares, totalAssets, totalShares);
    }
}

contract LibIlmSharesMathTest is Test {
    LibIlmSharesMathHarness internal h;

    function setUp() public {
        h = new LibIlmSharesMathHarness();
    }

    /// @dev Property 4: Share Math Rounding Directionality
    /// Validates: Requirements 8.1, 8.2, 8.3, 8.4
    function testFuzz_property4_roundingDirectionality(
        uint256 assetsRaw,
        uint256 sharesRaw,
        uint256 totalAssetsRaw,
        uint256 totalSharesRaw
    ) public {
        uint256 assets = bound(assetsRaw, 0, 1e24);
        uint256 shares = bound(sharesRaw, 0, 1e24);
        uint256 totalAssets = bound(totalAssetsRaw, 0, 1e24);
        uint256 totalShares = bound(totalSharesRaw, 0, 1e24);

        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;

        uint256 sharesDown = h.toSharesDown(assets, totalAssets, totalShares);
        uint256 sharesUp = h.toSharesUp(assets, totalAssets, totalShares);
        uint256 assetsDown = h.toAssetsDown(shares, totalAssets, totalShares);
        uint256 assetsUp = h.toAssetsUp(shares, totalAssets, totalShares);

        uint256 sharesNum = assets * adjustedShares;
        uint256 assetsNum = shares * adjustedAssets;

        uint256 expectedSharesDown = sharesNum / adjustedAssets;
        uint256 expectedSharesUp = _mulDivUp(assets, adjustedShares, adjustedAssets);
        uint256 expectedAssetsDown = assetsNum / adjustedShares;
        uint256 expectedAssetsUp = _mulDivUp(shares, adjustedAssets, adjustedShares);

        assertEq(sharesDown, expectedSharesDown);
        assertEq(sharesUp, expectedSharesUp);
        assertEq(assetsDown, expectedAssetsDown);
        assertEq(assetsUp, expectedAssetsUp);

        assertGe(sharesUp, sharesDown);
        assertGe(assetsUp, assetsDown);
    }

    /// @dev Property 5: Share Conversion Round-Trip Dust Bound
    /// Validates: Requirement 19.3
    function testFuzz_property5_roundTripDustBound(
        uint256 assetsRaw,
        uint256 sharesRaw,
        uint256 totalAssetsRaw,
        uint256 totalSharesRaw
    ) public {
        uint256 assets = bound(assetsRaw, 1, 1e24);
        uint256 shares = bound(sharesRaw, 1, 1e24);
        uint256 totalAssets = bound(totalAssetsRaw, 0, 1e24);
        uint256 totalShares = bound(totalSharesRaw, 0, 1e24);

        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;

        uint256 sharesFromAssets = h.toSharesDown(assets, totalAssets, totalShares);
        uint256 assetsRoundTrip = h.toAssetsUp(sharesFromAssets, totalAssets, totalShares);

        // Floor then ceil in inverse direction should not create net assets.
        assertLe(assetsRoundTrip, assets);
        uint256 assetDustLoss = assets - assetsRoundTrip;
        uint256 maxAssetDust = _ceilDiv(adjustedAssets, adjustedShares);
        assertLe(assetDustLoss, maxAssetDust);

        uint256 assetsFromShares = h.toAssetsDown(shares, totalAssets, totalShares);
        uint256 sharesRoundTrip = h.toSharesUp(assetsFromShares, totalAssets, totalShares);

        // Floor then ceil in inverse direction should not create net shares.
        assertLe(sharesRoundTrip, shares);
        uint256 shareDustLoss = shares - sharesRoundTrip;
        uint256 maxShareDust = _ceilDiv(adjustedShares, adjustedAssets);
        assertLe(shareDustLoss, maxShareDust);
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        return (a * b - 1) / d + 1;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a == 0) ? 0 : (a - 1) / b + 1;
    }
}


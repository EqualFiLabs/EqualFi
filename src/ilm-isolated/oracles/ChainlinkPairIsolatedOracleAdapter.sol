// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IIlmIsolatedOracleAdapter} from "../interfaces/IIlmIsolatedOracleAdapter.sol";

interface IChainlinkAggregatorV3Like {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @notice ILM isolated oracle adapter backed by a Chainlink USD pair.
/// @dev Converts:
///      - base/USD feed (collateral-side asset)
///      - quote/USD feed (loan-side asset)
///      into base/quote with ILM's expected normalization:
///      collateralAssets(base units) * price / 1e36 = borrowAssets(quote units).
contract ChainlinkPairIsolatedOracleAdapter is IIlmIsolatedOracleAdapter {
    error InvalidFeedAddress();
    error InvalidFeedAnswer(address feed, int256 answer);
    error InvalidFeedTimestamp(address feed, uint256 updatedAt);
    error ScaleExponentTooLarge(uint256 exponent);

    IChainlinkAggregatorV3Like public immutable baseUsdFeed;
    IChainlinkAggregatorV3Like public immutable quoteUsdFeed;
    uint8 public immutable baseAssetDecimals;
    uint8 public immutable quoteAssetDecimals;
    uint8 public immutable baseFeedDecimals;
    uint8 public immutable quoteFeedDecimals;
    uint256 public immutable numeratorScale;
    uint256 public immutable denominatorScale;

    constructor(address baseUsdFeed_, address quoteUsdFeed_, uint8 baseAssetDecimals_, uint8 quoteAssetDecimals_) {
        if (baseUsdFeed_ == address(0) || quoteUsdFeed_ == address(0)) {
            revert InvalidFeedAddress();
        }

        baseUsdFeed = IChainlinkAggregatorV3Like(baseUsdFeed_);
        quoteUsdFeed = IChainlinkAggregatorV3Like(quoteUsdFeed_);
        baseAssetDecimals = baseAssetDecimals_;
        quoteAssetDecimals = quoteAssetDecimals_;
        baseFeedDecimals = baseUsdFeed.decimals();
        quoteFeedDecimals = quoteUsdFeed.decimals();

        // base/quote scaled for ILM: 1e36 + quote asset units - base asset units.
        // Include feed fixed-point scaling directly to avoid per-call exponent math.
        numeratorScale = _pow10(uint256(quoteFeedDecimals) + 36 + uint256(quoteAssetDecimals_));
        denominatorScale = _pow10(uint256(baseFeedDecimals) + uint256(baseAssetDecimals_));
    }

    function getIsolatedPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        (, int256 baseAnswer,, uint256 baseUpdatedAt,) = baseUsdFeed.latestRoundData();
        (, int256 quoteAnswer,, uint256 quoteUpdatedAt,) = quoteUsdFeed.latestRoundData();

        if (baseAnswer <= 0) {
            revert InvalidFeedAnswer(address(baseUsdFeed), baseAnswer);
        }
        if (quoteAnswer <= 0) {
            revert InvalidFeedAnswer(address(quoteUsdFeed), quoteAnswer);
        }
        if (baseUpdatedAt == 0) {
            revert InvalidFeedTimestamp(address(baseUsdFeed), baseUpdatedAt);
        }
        if (quoteUpdatedAt == 0) {
            revert InvalidFeedTimestamp(address(quoteUsdFeed), quoteUpdatedAt);
        }

        uint256 denominator = uint256(quoteAnswer) * denominatorScale;
        price = Math.mulDiv(uint256(baseAnswer), numeratorScale, denominator);
        updatedAt = baseUpdatedAt < quoteUpdatedAt ? baseUpdatedAt : quoteUpdatedAt;
    }

    function _pow10(uint256 exponent) internal pure returns (uint256) {
        // 10^77 fits in uint256, 10^78 does not.
        if (exponent > 77) {
            revert ScaleExponentTooLarge(exponent);
        }
        return 10 ** exponent;
    }
}

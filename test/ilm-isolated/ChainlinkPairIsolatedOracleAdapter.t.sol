// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPairIsolatedOracleAdapter} from "../../src/ilm-isolated/oracles/ChainlinkPairIsolatedOracleAdapter.sol";

contract MockChainlinkAggregatorV3 {
    uint8 public immutable decimals;
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal roundId;
    uint80 internal answeredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
        roundId = 1;
        answeredInRound = 1;
    }

    function setRoundData(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
        answeredInRound = roundId;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

contract ChainlinkPairIsolatedOracleAdapterTest is Test {
    MockChainlinkAggregatorV3 internal ethUsd;
    MockChainlinkAggregatorV3 internal usdcUsd;
    ChainlinkPairIsolatedOracleAdapter internal adapterEthUsdc;
    ChainlinkPairIsolatedOracleAdapter internal adapterUsdcEth;

    function setUp() public {
        ethUsd = new MockChainlinkAggregatorV3(8);
        usdcUsd = new MockChainlinkAggregatorV3(8);

        // ETH/USD = 2000, USDC/USD = 1
        ethUsd.setRoundData(2000e8, 1_700_000_100);
        usdcUsd.setRoundData(1e8, 1_700_000_000);

        // Collateral ETH (18), loan USDC (6)
        adapterEthUsdc = new ChainlinkPairIsolatedOracleAdapter(address(ethUsd), address(usdcUsd), 18, 6);
        // Collateral USDC (6), loan ETH (18)
        adapterUsdcEth = new ChainlinkPairIsolatedOracleAdapter(address(usdcUsd), address(ethUsd), 6, 18);
    }

    function test_getIsolatedPrice_ethToUsdc_unitsAreCorrect() public {
        (uint256 price, uint256 updatedAt) = adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));

        // 1 ETH -> 2000 USDC in borrow asset units:
        // price = 2000 * 10^(36 + 6 - 18) = 2000e24
        assertEq(price, 2000e24);
        assertEq(updatedAt, 1_700_000_000);
    }

    function test_getIsolatedPrice_usdcToEth_unitsAreCorrect() public {
        (uint256 price, uint256 updatedAt) = adapterUsdcEth.getIsolatedPrice(address(adapterUsdcEth));

        // 1 USDC -> 0.0005 ETH in borrow asset units:
        // price = 0.0005 * 10^(36 + 18 - 6) = 5e44
        assertEq(price, 5e44);
        assertEq(updatedAt, 1_700_000_000);
    }

    function test_getIsolatedPrice_usesMinUpdatedAtAcrossFeeds() public {
        ethUsd.setRoundData(2100e8, 1_800_000_200);
        usdcUsd.setRoundData(1e8, 1_800_000_050);

        (, uint256 updatedAt) = adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));
        assertEq(updatedAt, 1_800_000_050);
    }

    function test_getIsolatedPrice_revertWhenBaseFeedAnswerNonPositive() public {
        ethUsd.setRoundData(0, 1_700_000_100);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPairIsolatedOracleAdapter.InvalidFeedAnswer.selector, address(ethUsd), int256(0)
            )
        );
        adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));
    }

    function test_getIsolatedPrice_revertWhenQuoteFeedAnswerNonPositive() public {
        usdcUsd.setRoundData(-1, 1_700_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPairIsolatedOracleAdapter.InvalidFeedAnswer.selector, address(usdcUsd), int256(-1)
            )
        );
        adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));
    }

    function test_getIsolatedPrice_revertWhenBaseFeedTimestampZero() public {
        ethUsd.setRoundData(2000e8, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPairIsolatedOracleAdapter.InvalidFeedTimestamp.selector, address(ethUsd), uint256(0)
            )
        );
        adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));
    }

    function test_getIsolatedPrice_revertWhenQuoteFeedTimestampZero() public {
        usdcUsd.setRoundData(1e8, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPairIsolatedOracleAdapter.InvalidFeedTimestamp.selector, address(usdcUsd), uint256(0)
            )
        );
        adapterEthUsdc.getIsolatedPrice(address(adapterEthUsdc));
    }

    function test_constructor_revertOnZeroFeedAddress() public {
        vm.expectRevert(ChainlinkPairIsolatedOracleAdapter.InvalidFeedAddress.selector);
        new ChainlinkPairIsolatedOracleAdapter(address(0), address(usdcUsd), 18, 6);

        vm.expectRevert(ChainlinkPairIsolatedOracleAdapter.InvalidFeedAddress.selector);
        new ChainlinkPairIsolatedOracleAdapter(address(ethUsd), address(0), 18, 6);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";

/// @notice Unit tests for ERC-1155 per-series URI overrides and fallback
contract DerivativeTokenUriTest is Test {
    address internal constant MANAGER = address(0xBEEF);

    OptionToken internal optionToken;
    FuturesToken internal futuresToken;

    function setUp() public {
        optionToken = new OptionToken("ipfs://base/options", address(this), MANAGER);
        futuresToken = new FuturesToken("ipfs://base/futures", address(this), MANAGER);
    }

    function testOptionTokenSeriesUriFallback() public {
        assertEq(optionToken.uri(1), "ipfs://base/options", "base uri fallback");

        vm.prank(MANAGER);
        optionToken.setSeriesURI(1, "ipfs://series/options/1");

        assertEq(optionToken.uri(1), "ipfs://series/options/1", "series uri override");
        assertEq(optionToken.uri(2), "ipfs://base/options", "other series fallback");
    }

    function testFuturesTokenSeriesUriFallback() public {
        assertEq(futuresToken.uri(7), "ipfs://base/futures", "base uri fallback");

        vm.prank(MANAGER);
        futuresToken.setSeriesURI(7, "ipfs://series/futures/7");

        assertEq(futuresToken.uri(7), "ipfs://series/futures/7", "series uri override");
        assertEq(futuresToken.uri(8), "ipfs://base/futures", "other series fallback");
    }
}

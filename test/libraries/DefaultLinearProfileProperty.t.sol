// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DefaultLinearProfile} from "src/profiles/DefaultLinearProfile.sol";
import {LibMamMath} from "src/libraries/LibMamMath.sol";

contract DefaultLinearProfilePropertyTest is Test {
    DefaultLinearProfile internal profile;

    function setUp() public {
        profile = new DefaultLinearProfile();
    }

    function testFuzz_defaultLinearProfileMatchesLibMamMath(
        uint128 startPrice,
        uint128 endPrice,
        uint64 startTime,
        uint64 duration,
        uint64 currentTime,
        bytes32 profileParams
    ) public {
        uint256 expected = LibMamMath.computePrice(startPrice, endPrice, startTime, duration, currentTime);
        uint256 actual = profile.computePrice(startPrice, endPrice, startTime, duration, currentTime, profileParams);
        assertEq(actual, expected, "DefaultLinearProfile must match LibMamMath");
    }
}

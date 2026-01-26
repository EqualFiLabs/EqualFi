// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {MamTypes} from "src/libraries/MamTypes.sol";
import {LibMamCurveHasher} from "src/libraries/LibMamCurveHasher.sol";
import {LibMamMath} from "src/libraries/LibMamMath.sol";

contract LibMamMathTest is Test {
    function _baseDescriptor() internal pure returns (MamTypes.CurveDescriptor memory desc) {
        desc.makerPositionKey = bytes32(uint256(1));
        desc.makerPositionId = 1;
        desc.poolIdA = 10;
        desc.poolIdB = 11;
        desc.tokenA = address(0xA);
        desc.tokenB = address(0xB);
        desc.side = false;
        desc.priceIsQuotePerBase = true;
        desc.maxVolume = 100 ether;
        desc.startPrice = 2e18;
        desc.endPrice = 1e18;
        desc.startTime = 100;
        desc.duration = 100;
        desc.generation = 1;
        desc.feeRateBps = 25;
        desc.feeAsset = MamTypes.FeeAsset.TokenIn;
        desc.salt = 1;
    }

    function testCurveHashChangesWithSalt() public {
        MamTypes.CurveDescriptor memory desc = _baseDescriptor();
        bytes32 initialHash = LibMamCurveHasher.curveHash(desc);
        desc.salt = 999;
        bytes32 newHash = LibMamCurveHasher.curveHash(desc);
        assertTrue(initialHash != newHash, "salt must alter commitment");
    }

    function testComputePriceBounds() public {
        uint256 startPrice = 2e18;
        uint256 endPrice = 1e18;
        uint256 startTime = 100;
        uint256 duration = 100;

        uint256 atStart = LibMamMath.computePrice(startPrice, endPrice, startTime, duration, 100);
        uint256 beforeStart = LibMamMath.computePrice(startPrice, endPrice, startTime, duration, 50);
        uint256 atEnd = LibMamMath.computePrice(startPrice, endPrice, startTime, duration, 200);
        uint256 afterEnd = LibMamMath.computePrice(startPrice, endPrice, startTime, duration, 250);

        assertEq(atStart, startPrice);
        assertEq(beforeStart, startPrice);
        assertEq(atEnd, endPrice);
        assertEq(afterEnd, endPrice);
    }

    function testComputePriceLinear() public {
        uint256 price = LibMamMath.computePrice(2e18, 1e18, 100, 100, 150);
        assertEq(price, 15e17);
    }
}

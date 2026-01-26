// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibCommunityAuctionFeeIndex} from "../../src/libraries/LibCommunityAuctionFeeIndex.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";

contract CommunityAuctionFeeIndexPropertyTest is Test {
    function testFuzz_CommunityFeeIndexAccrualA(
        uint256 startIndex,
        uint256 totalShares,
        uint256 amount,
        uint256 remainderA,
        uint256 startIndexB,
        uint256 remainderB
    ) external {
        vm.assume(totalShares > 0);
        vm.assume(amount > 0);
        vm.assume(amount <= type(uint256).max / LibCommunityAuctionFeeIndex.INDEX_SCALE);
        uint256 scaledAmount = Math.mulDiv(amount, LibCommunityAuctionFeeIndex.INDEX_SCALE, 1);
        vm.assume(remainderA < totalShares);
        vm.assume(remainderA <= type(uint256).max - scaledAmount);

        uint256 auctionId = 1;
        uint256 dividend = scaledAmount + remainderA;
        uint256 delta = dividend / totalShares;
        uint256 expectedRemainder = dividend - Math.mulDiv(delta, totalShares, 1);
        vm.assume(startIndex <= type(uint256).max - delta);

        DerivativeTypes.CommunityAuction storage auction = LibDerivativeStorage.derivativeStorage().communityAuctions[
            auctionId
        ];
        auction.totalShares = totalShares;
        auction.feeIndexA = startIndex;
        auction.feeIndexRemainderA = remainderA;
        auction.feeIndexB = startIndexB;
        auction.feeIndexRemainderB = remainderB;

        LibCommunityAuctionFeeIndex.accrueTokenAFee(auctionId, amount);

        assertEq(auction.feeIndexA, startIndex + delta, "fee index A accrues");
        assertEq(auction.feeIndexRemainderA, expectedRemainder, "fee index A remainder");
        assertEq(auction.feeIndexB, startIndexB, "fee index B unchanged");
        assertEq(auction.feeIndexRemainderB, remainderB, "fee index B remainder unchanged");
    }

    function testFuzz_CommunityFeeIndexAccrualB(
        uint256 startIndex,
        uint256 totalShares,
        uint256 amount,
        uint256 remainderB,
        uint256 startIndexA,
        uint256 remainderA
    ) external {
        vm.assume(totalShares > 0);
        vm.assume(amount > 0);
        vm.assume(amount <= type(uint256).max / LibCommunityAuctionFeeIndex.INDEX_SCALE);
        uint256 scaledAmount = Math.mulDiv(amount, LibCommunityAuctionFeeIndex.INDEX_SCALE, 1);
        vm.assume(remainderB < totalShares);
        vm.assume(remainderB <= type(uint256).max - scaledAmount);

        uint256 auctionId = 2;
        uint256 dividend = scaledAmount + remainderB;
        uint256 delta = dividend / totalShares;
        uint256 expectedRemainder = dividend - Math.mulDiv(delta, totalShares, 1);
        vm.assume(startIndex <= type(uint256).max - delta);

        DerivativeTypes.CommunityAuction storage auction = LibDerivativeStorage.derivativeStorage().communityAuctions[
            auctionId
        ];
        auction.totalShares = totalShares;
        auction.feeIndexB = startIndex;
        auction.feeIndexRemainderB = remainderB;
        auction.feeIndexA = startIndexA;
        auction.feeIndexRemainderA = remainderA;

        LibCommunityAuctionFeeIndex.accrueTokenBFee(auctionId, amount);

        assertEq(auction.feeIndexB, startIndex + delta, "fee index B accrues");
        assertEq(auction.feeIndexRemainderB, expectedRemainder, "fee index B remainder");
        assertEq(auction.feeIndexA, startIndexA, "fee index A unchanged");
        assertEq(auction.feeIndexRemainderA, remainderA, "fee index A remainder unchanged");
    }
}

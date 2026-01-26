// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";

contract CommunityAuctionStorageTest is Test {
    function testCommunityAuctionLists() external {
        bytes32 positionKey = bytes32(uint256(1));
        address tokenA = address(0xA11CE);
        address tokenB = address(0xB0B);
        uint256 poolId = 42;
        uint256 auctionId1 = 1;
        uint256 auctionId2 = 2;
        uint256 makerId1 = 101;
        uint256 makerId2 = 202;

        LibDerivativeStorage.addCommunityAuction(positionKey, auctionId1);
        LibDerivativeStorage.addCommunityAuction(positionKey, auctionId2);
        LibDerivativeStorage.addCommunityAuctionGlobal(auctionId1);
        LibDerivativeStorage.addCommunityAuctionGlobal(auctionId2);
        LibDerivativeStorage.addCommunityAuctionByPair(tokenA, tokenB, auctionId1);
        LibDerivativeStorage.addCommunityAuctionByPair(tokenA, tokenB, auctionId2);
        LibDerivativeStorage.addCommunityAuctionByPool(poolId, auctionId1);
        LibDerivativeStorage.addCommunityAuctionByPool(poolId, auctionId2);
        LibDerivativeStorage.addCommunityAuctionMaker(auctionId1, makerId1);
        LibDerivativeStorage.addCommunityAuctionMaker(auctionId1, makerId2);

        (uint256[] memory ids, uint256 total) = LibDerivativeStorage.communityAuctionsPage(positionKey, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], auctionId1);
        assertEq(ids[1], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsGlobalPage(0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], auctionId1);
        assertEq(ids[1], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsByPairPage(tokenA, tokenB, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], auctionId1);
        assertEq(ids[1], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsByPoolPage(poolId, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], auctionId1);
        assertEq(ids[1], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionMakersPage(auctionId1, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], makerId1);
        assertEq(ids[1], makerId2);

        LibDerivativeStorage.removeCommunityAuction(positionKey, auctionId1);
        LibDerivativeStorage.removeCommunityAuctionGlobal(auctionId1);
        LibDerivativeStorage.removeCommunityAuctionByPair(tokenA, tokenB, auctionId1);
        LibDerivativeStorage.removeCommunityAuctionByPool(poolId, auctionId1);
        LibDerivativeStorage.removeCommunityAuctionMaker(auctionId1, makerId1);

        (ids, total) = LibDerivativeStorage.communityAuctionsPage(positionKey, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsGlobalPage(0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsByPairPage(tokenA, tokenB, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionsByPoolPage(poolId, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], auctionId2);

        (ids, total) = LibDerivativeStorage.communityAuctionMakersPage(auctionId1, 0, 10);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], makerId2);
    }
}

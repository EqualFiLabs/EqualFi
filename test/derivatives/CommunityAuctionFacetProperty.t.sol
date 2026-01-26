// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    CommunityAuctionFacet,
    CommunityAuction_InvalidRatio,
    CommunityAuction_NotCreator,
    CommunityAuction_AlreadyStarted,
    CommunityAuction_InvalidAmount
} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibCommunityAuctionFeeIndex} from "../../src/libraries/LibCommunityAuctionFeeIndex.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Property: community auction creation initializes state correctly.
/// @notice Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.8
/// forge-config: default.fuzz.runs = 100
contract CommunityAuctionFacetPropertyTest is Test {
    CommunityAuctionHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal joiner = address(0xB0B);
    address internal taker = address(0xCAFE);
    address internal treasury = address(0xBEEF);
    address internal swapper = address(0xD00D);

    function setUp() public {
        harness = new CommunityAuctionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setMakerShareBps(7000);
        vm.label(swapper, "swapper");
    }

    function _createAuction(uint96 reserveA, uint96 reserveB, uint64 startTime, uint64 endTime)
        internal
        returns (uint256 auctionId, uint256 makerTokenId, bytes32 makerKey)
    {
        makerTokenId = nft.mint(maker, 1);
        makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: startTime,
            endTime: endTime,
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        auctionId = harness.createCommunityAuction(params);
    }

    function testProperty_CreateCommunityAuctionInitializesState(uint96 reserveA, uint96 reserveB) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = uint256(reserveA) + 1e6;
        uint256 principalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), positionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory makerPos = harness.getCommunityMaker(auctionId, positionKey);
        uint256 expectedShare = Math.sqrt(Math.mulDiv(reserveA, reserveB, 1));

        assertEq(auction.reserveA, reserveA, "reserve A");
        assertEq(auction.reserveB, reserveB, "reserve B");
        assertEq(auction.feeIndexA, 0, "fee index A");
        assertEq(auction.feeIndexB, 0, "fee index B");
        assertEq(auction.feeIndexRemainderA, 0, "fee remainder A");
        assertEq(auction.feeIndexRemainderB, 0, "fee remainder B");
        assertEq(auction.totalShares, expectedShare, "total shares");
        assertEq(auction.makerCount, 1, "maker count");
        assertTrue(auction.active, "auction active");
        assertFalse(auction.finalized, "auction not finalized");

        assertEq(makerPos.share, expectedShare, "maker share");
        assertEq(makerPos.feeIndexSnapshotA, 0, "snapshot A");
        assertEq(makerPos.feeIndexSnapshotB, 0, "snapshot B");
        assertEq(makerPos.initialContributionA, reserveA, "initial contribution A");
        assertEq(makerPos.initialContributionB, reserveB, "initial contribution B");
        assertTrue(makerPos.isParticipant, "maker participant");

        assertEq(harness.getDirectLent(positionKey, 1), reserveA, "lent principal A");
        assertEq(harness.getDirectLent(positionKey, 2), reserveB, "lent principal B");
    }

    function testProperty_JoinAccountingInvariant(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        vm.assume(mulmod(amountA, reserveB, reserveA) == 0);
        vm.assume(mulmod(amountA, reserveB, reserveA) == 0);
        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        DerivativeTypes.CommunityAuction memory beforeAuction = harness.getCommunityAuction(auctionId);
        uint256 beforeShares = beforeAuction.totalShares;

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        DerivativeTypes.CommunityAuction memory afterAuction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory joinerPos = harness.getCommunityMaker(auctionId, joinerKey);
        uint256 expectedShare = Math.sqrt(Math.mulDiv(amountA, expectedB, 1));

        assertEq(afterAuction.reserveA, beforeAuction.reserveA + amountA, "reserve A updated");
        assertEq(afterAuction.reserveB, beforeAuction.reserveB + expectedB, "reserve B updated");
        assertEq(afterAuction.totalShares, beforeShares + expectedShare, "total shares updated");
        assertEq(afterAuction.makerCount, beforeAuction.makerCount + 1, "maker count updated");

        assertEq(joinerPos.share, expectedShare, "joiner share");
        assertEq(joinerPos.feeIndexSnapshotA, beforeAuction.feeIndexA, "joiner snapshot A");
        assertEq(joinerPos.feeIndexSnapshotB, beforeAuction.feeIndexB, "joiner snapshot B");

        assertEq(harness.getDirectLent(joinerKey, 1), amountA, "joiner lent A");
        assertEq(harness.getDirectLent(joinerKey, 2), expectedB, "joiner lent B");
    }

    function testProperty_ReserveRatioEnforcement(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);
        uint256 tolerance = expectedB / 1000;
        uint256 badB = expectedB + tolerance + 1;

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, badB + 1e6, badB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_InvalidRatio.selector, expectedB, badB));
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, badB);
    }

    function testProperty_LeaveReturnsProportionalReservesPlusFees(
        uint96 reserveA,
        uint96 reserveB,
        uint96 amountA,
        uint96 feeA,
        uint96 feeB
    ) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        feeA = uint96(bound(feeA, 0, 1e18));
        feeB = uint96(bound(feeB, 0, 1e18));
        vm.assume(feeA < reserveA && feeB < reserveB);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        DerivativeTypes.CommunityAuction memory beforeAuction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory joinerPos = harness.getCommunityMaker(auctionId, joinerKey);

        if (feeA > 0) {
            harness.accrueCommunityFeeA(auctionId, feeA);
        }
        if (feeB > 0) {
            harness.accrueCommunityFeeB(auctionId, feeB);
        }

        DerivativeTypes.CommunityAuction memory afterAccrual = harness.getCommunityAuction(auctionId);
        uint256 reserveAForWithdrawal = afterAccrual.reserveA;
        uint256 reserveBForWithdrawal = afterAccrual.reserveB;
        (uint256 expectedFeesA, uint256 expectedFeesB) = harness.pendingCommunityFees(auctionId, joinerKey);
        if (expectedFeesA > 0) {
            if (expectedFeesA > reserveAForWithdrawal) {
                expectedFeesA = reserveAForWithdrawal;
            }
            reserveAForWithdrawal -= expectedFeesA;
        }
        if (expectedFeesB > 0) {
            if (expectedFeesB > reserveBForWithdrawal) {
                expectedFeesB = reserveBForWithdrawal;
            }
            reserveBForWithdrawal -= expectedFeesB;
        }
        uint256 expectedWithdrawA = Math.mulDiv(reserveAForWithdrawal, joinerPos.share, beforeAuction.totalShares);
        uint256 expectedWithdrawB = Math.mulDiv(reserveBForWithdrawal, joinerPos.share, beforeAuction.totalShares);

        if (expectedFeesA > afterAccrual.reserveA || expectedFeesB > afterAccrual.reserveB) return;

        vm.prank(joiner);
        (uint256 withdrawnA, uint256 withdrawnB, uint256 feesAOut, uint256 feesBOut) =
            harness.leaveCommunityAuction(auctionId, joinerTokenId);

        assertEq(withdrawnA, expectedWithdrawA, "withdraw A");
        assertEq(withdrawnB, expectedWithdrawB, "withdraw B");
        assertEq(feesAOut, expectedFeesA, "fees A");
        assertEq(feesBOut, expectedFeesB, "fees B");
        assertEq(harness.getAccruedYield(1, joinerKey), expectedFeesA, "accrued yield A");
        assertEq(harness.getAccruedYield(2, joinerKey), expectedFeesB, "accrued yield B");
    }

    function testProperty_JoinLeaveRoundTripNoSwaps(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        vm.prank(joiner);
        (uint256 withdrawnA, uint256 withdrawnB,,) = harness.leaveCommunityAuction(auctionId, joinerTokenId);

        assertApproxEqAbs(withdrawnA, amountA, 1e6, "round trip A");
        assertApproxEqAbs(withdrawnB, expectedB, 1e6, "round trip B");
    }

    function testProperty_SwapTrackedBalanceIsolation() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 3e18, 3e18);
        harness.seedPool(2, address(tokenB), positionKey, 9e18, 9e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 100,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        uint256 amountIn = 1e18;
        tokenA.mint(swapper, amountIn);
        vm.prank(swapper);
        tokenA.approve(address(harness), amountIn);

        uint256 trackedBeforeA = harness.getTrackedBalance(1);
        uint256 trackedBeforeB = harness.getTrackedBalance(2);

        vm.prank(swapper);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, 0, swapper);

        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        uint256 feeAmount = (amountIn * 100) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        uint16 activeBps = harness.getActiveCreditSplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 treasuryFee = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;
        uint256 activeFee = (protocolFee * activeBps) / 10_000;
        uint256 indexFee = protocolFee - treasuryFee - activeFee;
        assertEq(auction.reserveA, 2e18 + amountIn - treasuryFee, "reserve A updated");
        assertLt(auction.reserveB, 2e18, "reserve B reduced");
        assertEq(harness.getTrackedBalance(1), trackedBeforeA + indexFee + activeFee, "tracked A updated");
        assertEq(harness.getTrackedBalance(2), trackedBeforeB, "tracked B unchanged during swap");
    }

    function testProperty_FinalizationDistributesAllReserves(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 1 days);
        (uint256 auctionId, uint256 makerTokenId,) = _createAuction(reserveA, reserveB, startTime, endTime);

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        DerivativeTypes.CommunityAuction memory finalAuction = harness.getCommunityAuction(auctionId);
        vm.warp(endTime + 1);
        harness.finalizeAuction(auctionId);

        vm.prank(joiner);
        (uint256 joinerA, uint256 joinerB,,) = harness.leaveCommunityAuction(auctionId, joinerTokenId);
        vm.prank(maker);
        (uint256 makerA, uint256 makerB,,) = harness.leaveCommunityAuction(auctionId, makerTokenId);

        assertApproxEqAbs(joinerA + makerA, finalAuction.reserveA, 1, "final reserve A");
        assertApproxEqAbs(joinerB + makerB, finalAuction.reserveB, 1, "final reserve B");
    }

    function testProperty_CancelAuthorizationEnforcement(uint96 reserveA, uint96 reserveB) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));

        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 2 days);
        (uint256 auctionId,, bytes32 makerKey) = _createAuction(reserveA, reserveB, startTime, endTime);

        vm.prank(joiner);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_NotCreator.selector, makerKey));
        harness.cancelCommunityAuction(auctionId);
    }

    function testProperty_CancelTimeRestriction(uint96 reserveA, uint96 reserveB) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));

        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 1 days);
        (uint256 auctionId,,) = _createAuction(reserveA, reserveB, startTime, endTime);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(CommunityAuction_AlreadyStarted.selector, auctionId));
        harness.cancelCommunityAuction(auctionId);
    }

    function testProperty_ProRataFeeDistribution(
        uint96 reserveA,
        uint96 reserveB,
        uint96 amountA,
        uint96 amountIn
    ) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA / 2));
        amountIn = uint96(bound(amountIn, 1e4, reserveA / 2));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        harness.setTreasury(treasury);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 makerPrincipalA = uint256(reserveA) + 1e6;
        uint256 makerPrincipalB = uint256(reserveB) + 1e6;
        harness.seedPool(1, address(tokenA), makerKey, makerPrincipalA, makerPrincipalA);
        harness.seedPool(2, address(tokenB), makerKey, makerPrincipalB, makerPrincipalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        DerivativeTypes.CreateCommunityAuctionParams memory params = DerivativeTypes.CreateCommunityAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(params);

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        harness.setPoolTrackedBalance(2, uint256(reserveB) + expectedB + 1e6);

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, 0, taker);

        DerivativeTypes.CommunityAuction memory auctionAfter = harness.getCommunityAuction(auctionId);
        (uint256 makerFeesA,) = harness.pendingCommunityFees(auctionId, makerKey);
        (uint256 joinerFeesA,) = harness.pendingCommunityFees(auctionId, joinerKey);

        uint256 feeAmount = Math.mulDiv(amountIn, params.feeBps, 10_000);
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 distributed = makerFeesA + joinerFeesA;
        uint256 remainderTokens = auctionAfter.feeIndexRemainderA / LibCommunityAuctionFeeIndex.INDEX_SCALE;

        assertLe(distributed, makerFee, "distributed <= maker fee");
        assertLe(makerFee - distributed, remainderTokens + auctionAfter.makerCount, "rounding tolerance");
    }

    function testProperty_ViewFunctions(uint96 reserveA, uint96 reserveB, uint96 amountA, uint96 feeA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        feeA = uint96(bound(feeA, 0, 1e12));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        (uint256 auctionId,, bytes32 makerKey) =
            _createAuction(reserveA, reserveB, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 previewB = harness.previewJoin(auctionId, amountA);
        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);
        assertEq(previewB, expectedB, "preview join");

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        if (feeA > 0) {
            harness.accrueCommunityFeeA(auctionId, feeA);
        }

        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory joinerPos = harness.getCommunityMaker(auctionId, joinerKey);
        uint256 expectedShare = Math.sqrt(Math.mulDiv(amountA, expectedB, 1));

        (uint256 share, uint256 pendingA, uint256 pendingB) = harness.getMakerShare(auctionId, joinerKey);
        assertEq(share, expectedShare, "maker share");
        assertEq(pendingB, 0, "pending B");

        uint256 expectedFeesA = 0;
        if (auction.feeIndexA > joinerPos.feeIndexSnapshotA) {
            expectedFeesA = Math.mulDiv(
                joinerPos.share,
                auction.feeIndexA - joinerPos.feeIndexSnapshotA,
                LibCommunityAuctionFeeIndex.INDEX_SCALE
            );
        }
        assertEq(pendingA, expectedFeesA, "pending A");

        (uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB) =
            harness.previewLeave(auctionId, joinerKey);
        uint256 expectedWithdrawA = Math.mulDiv(auction.reserveA, joinerPos.share, auction.totalShares);
        uint256 expectedWithdrawB = Math.mulDiv(auction.reserveB, joinerPos.share, auction.totalShares);
        assertEq(withdrawA, expectedWithdrawA, "preview leave A");
        assertEq(withdrawB, expectedWithdrawB, "preview leave B");
        assertEq(feesA, expectedFeesA, "preview fees A");
        assertEq(feesB, 0, "preview fees B");

        assertEq(harness.getTotalMakers(auctionId), auction.makerCount, "total makers");
        (uint256 creatorShare,,) = harness.getMakerShare(auctionId, makerKey);
        assertEq(creatorShare, auction.totalShares - expectedShare, "creator share");
    }

    function test_CommunitySwapKeepsIndexFeeInReserves() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 3 ether;
        uint256 reserveB = 9000 ether;
        uint256 amountIn = 1 ether;
        uint16 feeBps = 100;

        uint256 principalA = reserveA + 10 ether;
        uint256 principalB = reserveB + 10 ether;
        harness.seedPool(1, address(tokenA), makerKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerKey, principalB, principalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);
        harness.setTreasury(treasury);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: feeBps,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        tokenA.mint(taker, amountIn);
        vm.prank(taker);
        tokenA.approve(address(harness), amountIn);

        vm.prank(taker);
        harness.swapExactIn(auctionId, address(tokenA), amountIn, 0, taker);

        uint256 feeAmount = (amountIn * feeBps) / 10_000;
        uint16 makerShareBps = harness.getMakerShareBps();
        uint256 makerFee = (feeAmount * makerShareBps) / 10_000;
        uint256 protocolFee = feeAmount - makerFee;
        uint16 treasuryBps = harness.getTreasurySplitBps();
        address treasuryAddr = harness.getTreasuryAddress();
        uint256 expectedTreasury = treasuryAddr != address(0) ? (protocolFee * treasuryBps) / 10_000 : 0;
        uint256 expectedReserveA = reserveA + amountIn - expectedTreasury;

        DerivativeTypes.CommunityAuction memory auctionAfter = harness.getCommunityAuction(auctionId);
        assertEq(auctionAfter.reserveA, expectedReserveA, "reserve should retain index fee");
    }

    function test_CommunityJoinAllowsTopUp() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = nft.getPositionKey(makerTokenId);

        uint256 reserveA = 2 ether;
        uint256 reserveB = 2 ether;
        uint256 principalA = reserveA + 1 ether;
        uint256 principalB = reserveB + 1 ether;
        harness.seedPool(1, address(tokenA), makerKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerKey, principalB, principalB);
        harness.joinPool(makerKey, 1);
        harness.joinPool(makerKey, 2);

        vm.prank(maker);
        uint256 auctionId = harness.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: reserveA,
                reserveB: reserveB,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        DerivativeTypes.CommunityAuction memory beforeAuction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory beforeMaker = harness.getCommunityMaker(auctionId, makerKey);

        uint256 addA = 1 ether;
        uint256 addB = 1 ether;
        vm.prank(maker);
        harness.joinCommunityAuction(auctionId, makerTokenId, addA, addB);

        DerivativeTypes.CommunityAuction memory afterAuction = harness.getCommunityAuction(auctionId);
        DerivativeTypes.MakerPosition memory afterMaker = harness.getCommunityMaker(auctionId, makerKey);
        uint256 addedShare = Math.sqrt(Math.mulDiv(addA, addB, 1));

        assertEq(afterMaker.share, beforeMaker.share + addedShare, "maker share adds");
        assertEq(afterMaker.initialContributionA, beforeMaker.initialContributionA + addA, "contrib A adds");
        assertEq(afterMaker.initialContributionB, beforeMaker.initialContributionB + addB, "contrib B adds");
        assertEq(afterAuction.totalShares, beforeAuction.totalShares + addedShare, "total shares add");
        assertEq(afterAuction.makerCount, beforeAuction.makerCount, "maker count unchanged");
        assertEq(afterAuction.reserveA, beforeAuction.reserveA + addA, "reserve A adds");
        assertEq(afterAuction.reserveB, beforeAuction.reserveB + addB, "reserve B adds");
    }

    function testProperty_ShareInvariant(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        (uint256 auctionId, uint256 makerTokenId, bytes32 makerKey) =
            _createAuction(reserveA, reserveB, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        (uint256 makerShare,,) = harness.getMakerShare(auctionId, makerKey);
        (uint256 joinerShare,,) = harness.getMakerShare(auctionId, joinerKey);

        assertEq(makerShare + joinerShare, auction.totalShares, "total shares sum");
        assertEq(auction.makerCount, 2, "maker count");
    }

    function testProperty_ReserveInvariant(uint96 reserveA, uint96 reserveB, uint96 amountA) public {
        reserveA = uint96(bound(reserveA, 1e6, type(uint96).max));
        reserveB = uint96(bound(reserveB, 1e6, type(uint96).max));
        amountA = uint96(bound(amountA, 1e4, reserveA));
        vm.assume(uint256(reserveA) <= uint256(reserveB) * 1e6);
        vm.assume(uint256(reserveB) <= uint256(reserveA) * 1e6);

        (uint256 auctionId, uint256 makerTokenId, bytes32 makerKey) =
            _createAuction(reserveA, reserveB, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 expectedB = Math.mulDiv(amountA, reserveB, reserveA);
        vm.assume(expectedB > 0);

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        uint256 joinAmountA = uint256(amountA);
        harness.seedPool(1, address(tokenA), joinerKey, joinAmountA + 1e6, joinAmountA + 1e6);
        harness.seedPool(2, address(tokenB), joinerKey, expectedB + 1e6, expectedB + 1e6);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, amountA, expectedB);

        DerivativeTypes.CommunityAuction memory auction = harness.getCommunityAuction(auctionId);
        (uint256 makerShare,,) = harness.getMakerShare(auctionId, makerKey);
        (uint256 joinerShare,,) = harness.getMakerShare(auctionId, joinerKey);

        uint256 makerWithdrawA = Math.mulDiv(auction.reserveA, makerShare, auction.totalShares);
        uint256 makerWithdrawB = Math.mulDiv(auction.reserveB, makerShare, auction.totalShares);
        uint256 joinerWithdrawA = Math.mulDiv(auction.reserveA, joinerShare, auction.totalShares);
        uint256 joinerWithdrawB = Math.mulDiv(auction.reserveB, joinerShare, auction.totalShares);

        assertApproxEqAbs(makerWithdrawA + joinerWithdrawA, auction.reserveA, 1, "reserve A sum");
        assertApproxEqAbs(makerWithdrawB + joinerWithdrawB, auction.reserveB, 1, "reserve B sum");
        assertEq(auction.makerCount, 2, "maker count");
        assertEq(auction.totalShares, makerShare + joinerShare, "share sum");
    }

    function testJoinIndexesMakers() public {
        (uint256 auctionId, uint256 makerTokenId, bytes32 makerKey) =
            _createAuction(5e18, 10e18, uint64(block.timestamp), uint64(block.timestamp + 2 days));

        uint256 joinerTokenId = nft.mint(joiner, 1);
        bytes32 joinerKey = nft.getPositionKey(joinerTokenId);
        harness.seedPool(1, address(tokenA), joinerKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), joinerKey, 20e18, 20e18);
        harness.joinPool(joinerKey, 1);
        harness.joinPool(joinerKey, 2);

        vm.prank(joiner);
        harness.joinCommunityAuction(auctionId, joinerTokenId, 5e18, 10e18);

        (uint256[] memory ids, uint256 total) = harness.getCommunityAuctionMakerIds(auctionId, 0, 10);
        assertEq(total, 2, "maker index total");
        assertEq(ids.length, 2, "maker index length");
        assertTrue(
            (ids[0] == makerTokenId && ids[1] == joinerTokenId) ||
                (ids[0] == joinerTokenId && ids[1] == makerTokenId),
            "maker index members"
        );

        vm.prank(joiner);
        harness.leaveCommunityAuction(auctionId, joinerTokenId);

        (ids, total) = harness.getCommunityAuctionMakerIds(auctionId, 0, 10);
        assertEq(total, 1, "maker index total after leave");
        assertEq(ids.length, 1, "maker index length after leave");
        assertEq(ids[0], makerTokenId, "maker index remaining");
    }

    function test_MakerFeesBackedOnLeave() public {
        (uint256 auctionId, uint256 makerTokenId, bytes32 makerKey) =
            _createAuction(10e18, 20e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 feeA = 1e18;
        harness.accrueCommunityFeeA(auctionId, feeA);

        (, uint256 trackedBefore, uint256 yieldBefore) = harness.getPoolBacking(1);
        (uint256 expectedFeeA, ) = harness.pendingCommunityFees(auctionId, makerKey);

        vm.prank(maker);
        (, , uint256 feesA,) = harness.leaveCommunityAuction(auctionId, makerTokenId);

        (, uint256 trackedAfter, uint256 yieldAfter) = harness.getPoolBacking(1);
        // Maker fees are added to yieldReserve when settled (to back userAccruedYield)
        assertEq(yieldAfter, yieldBefore + feesA, "yield reserve increased by maker fees");
        // Principal is reduced by fees so tracked balance should not double count.
        assertApproxEqAbs(trackedAfter, trackedBefore, 10, "tracked balance not double-counted");
        assertEq(feesA, expectedFeeA, "fees settled match pending");
    }
}

contract CommunityAuctionHarness is CommunityAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps = shareBps;
    }

    function getMakerShareBps() external view returns (uint16) {
        return LibDerivativeStorage.derivativeStorage().config.communityMakerShareBps;
    }

    function getTreasurySplitBps() external view returns (uint16) {
        return LibAppStorage.treasurySplitBps(LibAppStorage.s());
    }

    function getActiveCreditSplitBps() external view returns (uint16) {
        return LibAppStorage.activeCreditSplitBps(LibAppStorage.s());
    }

    function getTreasuryAddress() external view returns (address) {
        return LibAppStorage.treasuryAddress(LibAppStorage.s());
    }

    function seedPool(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getCommunityAuctionData(uint256 auctionId) external view returns (DerivativeTypes.CommunityAuction memory) {
        return LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
    }

    function getCommunityMaker(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (DerivativeTypes.MakerPosition memory)
    {
        return LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
    }

    function getDirectLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function getCommunityAuctionMakerIds(uint256 auctionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.communityAuctionMakersPage(auctionId, offset, limit);
    }

    function getAccruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function pendingCommunityFees(uint256 auctionId, bytes32 positionKey) external view returns (uint256 feesA, uint256 feesB) {
        return LibCommunityAuctionFeeIndex.pendingFees(auctionId, positionKey);
    }

    function getPoolBacking(uint256 pid) external view returns (uint256 totalDeposits, uint256 trackedBalance, uint256 yieldReserve) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        yieldReserve = p.yieldReserve;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPoolTrackedBalance(uint256 pid, uint256 tracked) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (tracked > p.trackedBalance) {
            uint256 delta = tracked - p.trackedBalance;
            p.trackedBalance = tracked;
            MockERC20(p.underlying).mint(address(this), delta);
        } else {
            p.trackedBalance = tracked;
        }
    }

    function setPoolYieldReserve(uint256 pid, uint256 yieldReserve) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.yieldReserve = yieldReserve;
    }

    function accrueCommunityFeeA(uint256 auctionId, uint256 amount) external {
        LibCommunityAuctionFeeIndex.accrueTokenAFee(auctionId, amount);
    }

    function accrueCommunityFeeB(uint256 auctionId, uint256 amount) external {
        LibCommunityAuctionFeeIndex.accrueTokenBFee(auctionId, amount);
    }
}

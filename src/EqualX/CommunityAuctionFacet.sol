// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Types} from "../libraries/Types.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibCommunityAuctionFeeIndex} from "../libraries/LibCommunityAuctionFeeIndex.sol";
import {LibAuctionSwap} from "../libraries/LibAuctionSwap.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {PoolMembershipRequired, InsufficientPrincipal} from "../libraries/Errors.sol";
import {TransientSwapCache} from "../libraries/TransientSwapCache.sol";

error CommunityAuction_InvalidAmount(uint256 amount);
error CommunityAuction_InvalidRatio(uint256 expected, uint256 actual);
error CommunityAuction_InvalidPool(uint256 poolId);
error CommunityAuction_InvalidFee(uint16 feeBps, uint16 maxFeeBps);
error CommunityAuction_Paused();
error CommunityAuction_NotActive(uint256 auctionId);
error CommunityAuction_AlreadyFinalized(uint256 auctionId);
error CommunityAuction_NotExpired(uint256 auctionId);
error CommunityAuction_NotCreator(bytes32 positionKey);
error CommunityAuction_AlreadyStarted(uint256 auctionId);
error CommunityAuction_AlreadyParticipant(bytes32 positionKey);
error CommunityAuction_NotParticipant(bytes32 positionKey);
error CommunityAuction_InvalidToken(address token);
error CommunityAuction_Slippage(uint256 minOut, uint256 actualOut);

/// @notice Community auction facet allowing multiple makers to pool liquidity.
contract CommunityAuctionFacet is ReentrancyGuardModifiers {
    bytes32 internal constant COMMUNITY_FEE_SOURCE = keccak256("COMMUNITY_AUCTION_FEE");
    event CommunityAuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 indexed creatorPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        address tokenA,
        address tokenB,
        uint256 reserveA,
        uint256 reserveB,
        uint64 startTime,
        uint64 endTime,
        uint16 feeBps,
        DerivativeTypes.FeeAsset feeAsset
    );

    event MakerJoined(
        uint256 indexed auctionId,
        bytes32 indexed positionKey,
        uint256 positionId,
        uint256 amountA,
        uint256 amountB,
        uint256 share
    );

    event MakerLeft(
        uint256 indexed auctionId,
        bytes32 indexed positionKey,
        uint256 positionId,
        uint256 withdrawnA,
        uint256 withdrawnB,
        uint256 feesA,
        uint256 feesB
    );

    event FeesClaimed(uint256 indexed auctionId, bytes32 indexed positionKey, uint256 feesA, uint256 feesB);
    event CommunityAuctionSwapped(
        uint256 indexed auctionId,
        address indexed swapper,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );
    event CommunityAuctionFinalized(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 reserveA,
        uint256 reserveB
    );
    event CommunityAuctionCancelled(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 reserveA,
        uint256 reserveB
    );

    function createCommunityAuction(DerivativeTypes.CreateCommunityAuctionParams calldata params)
        external
        nonReentrant
        returns (uint256 auctionId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        if (ds.communityAuctionPaused) revert CommunityAuction_Paused();
        if (params.reserveA == 0 || params.reserveB == 0) {
            revert CommunityAuction_InvalidAmount(params.reserveA == 0 ? params.reserveA : params.reserveB);
        }
        if (params.poolIdA == params.poolIdB) revert CommunityAuction_InvalidPool(params.poolIdA);
        LibDerivativeHelpers._validateTimeWindow(params.startTime, params.endTime);

        if (ds.config.maxFeeBps != 0 && params.feeBps > ds.config.maxFeeBps) {
            revert CommunityAuction_InvalidFee(params.feeBps, ds.config.maxFeeBps);
        }

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(params.positionId);
        Types.PoolData storage poolA = LibDirectHelpers._pool(params.poolIdA);
        Types.PoolData storage poolB = LibDirectHelpers._pool(params.poolIdB);

        if (!LibPoolMembership.isMember(positionKey, params.poolIdA)) {
            revert PoolMembershipRequired(positionKey, params.poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, params.poolIdB)) {
            revert PoolMembershipRequired(positionKey, params.poolIdB);
        }

        LibFeeIndex.settle(params.poolIdA, positionKey);
        LibActiveCreditIndex.settle(params.poolIdA, positionKey);
        LibFeeIndex.settle(params.poolIdB, positionKey);
        LibActiveCreditIndex.settle(params.poolIdB, positionKey);

        LibDerivativeHelpers._lockAmmReserves(positionKey, params.poolIdA, params.reserveA);
        LibDerivativeHelpers._lockAmmReserves(positionKey, params.poolIdB, params.reserveB);

        auctionId = ++ds.nextCommunityAuctionId;
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        auction.creatorPositionKey = positionKey;
        auction.creatorPositionId = params.positionId;
        auction.poolIdA = params.poolIdA;
        auction.poolIdB = params.poolIdB;
        auction.tokenA = poolA.underlying;
        auction.tokenB = poolB.underlying;
        auction.reserveA = params.reserveA;
        auction.reserveB = params.reserveB;
        auction.feeBps = params.feeBps;
        auction.feeAsset = params.feeAsset;
        auction.totalShares = Math.sqrt(Math.mulDiv(params.reserveA, params.reserveB, 1));
        auction.makerCount = 1;
        auction.startTime = params.startTime;
        auction.endTime = params.endTime;
        auction.active = true;
        auction.finalized = false;

        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        maker.share = auction.totalShares;
        maker.feeIndexSnapshotA = 0;
        maker.feeIndexSnapshotB = 0;
        maker.initialContributionA = params.reserveA;
        maker.initialContributionB = params.reserveB;
        maker.isParticipant = true;

        LibDerivativeStorage.addCommunityAuction(positionKey, auctionId);
        LibDerivativeStorage.addCommunityAuctionGlobal(auctionId);
        LibDerivativeStorage.addCommunityAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
        LibDerivativeStorage.addCommunityAuctionByPool(auction.poolIdA, auctionId);
        LibDerivativeStorage.addCommunityAuctionByPool(auction.poolIdB, auctionId);
        LibDerivativeStorage.addCommunityAuctionMaker(auctionId, params.positionId);

        emit CommunityAuctionCreated(
            auctionId,
            positionKey,
            params.positionId,
            params.poolIdA,
            params.poolIdB,
            auction.tokenA,
            auction.tokenB,
            params.reserveA,
            params.reserveB,
            params.startTime,
            params.endTime,
            params.feeBps,
            params.feeAsset
        );
    }

    function leaveCommunityAuction(uint256 auctionId, uint256 positionId)
        external
        nonReentrant
        returns (uint256 withdrawnA, uint256 withdrawnB, uint256 feesA, uint256 feesB)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        if (auction.finalized && auction.totalShares == 0) {
            revert CommunityAuction_AlreadyFinalized(auctionId);
        }

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(positionId);
        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        if (!maker.isParticipant || maker.share == 0) {
            revert CommunityAuction_NotParticipant(positionKey);
        }

        Types.PoolData storage poolA = LibAppStorage.s().pools[auction.poolIdA];
        Types.PoolData storage poolB = LibAppStorage.s().pools[auction.poolIdB];

        LibActiveCreditIndex.settle(auction.poolIdA, positionKey);
        LibActiveCreditIndex.settle(auction.poolIdB, positionKey);

        (feesA, feesB) = LibCommunityAuctionFeeIndex.settleMaker(auctionId, positionKey);
        _backSettledMakerFees(auction, poolA, poolB, feesA, feesB);

        uint256 totalShares = auction.totalShares;

        // Calculate withdrawal from reserves EXCLUDING protocol yield (FI + ACI) backing yieldReserve
        if (totalShares > 0) {
            uint256 reservedA = auction.indexFeeAAccrued + auction.activeCreditFeeAAccrued;
            uint256 reservedB = auction.indexFeeBAccrued + auction.activeCreditFeeBAccrued;
            uint256 withdrawableReserveA = auction.reserveA > reservedA ? auction.reserveA - reservedA : 0;
            uint256 withdrawableReserveB = auction.reserveB > reservedB ? auction.reserveB - reservedB : 0;
            withdrawnA = Math.mulDiv(withdrawableReserveA, maker.share, totalShares);
            withdrawnB = Math.mulDiv(withdrawableReserveB, maker.share, totalShares);
        }

        // Compare against original contributions; fees are already credited via userAccruedYield
        // and backed by _backSettledMakerFees, so subtracting them would double-count gains.
        uint256 initialA = maker.initialContributionA;
        uint256 initialB = maker.initialContributionB;

        _applyPrincipalDelta(auction.poolIdA, poolA, positionKey, withdrawnA, initialA);
        _applyPrincipalDelta(auction.poolIdB, poolB, positionKey, withdrawnB, initialB);

        if (maker.initialContributionA > 0) {
            LibDerivativeHelpers._unlockAmmReserves(positionKey, auction.poolIdA, maker.initialContributionA);
            LibActiveCreditIndex.applyEncumbranceDecrease(
                poolA, auction.poolIdA, positionKey, maker.initialContributionA
            );
        }
        if (maker.initialContributionB > 0) {
            LibDerivativeHelpers._unlockAmmReserves(positionKey, auction.poolIdB, maker.initialContributionB);
            LibActiveCreditIndex.applyEncumbranceDecrease(
                poolB, auction.poolIdB, positionKey, maker.initialContributionB
            );
        }

        // Deduct withdrawn amount from reserves; protocol yield stays reserved in auction
        auction.reserveA -= withdrawnA;
        auction.reserveB -= withdrawnB;
        auction.totalShares = totalShares - maker.share;
        auction.makerCount -= 1;

        maker.share = 0;
        maker.initialContributionA = 0;
        maker.initialContributionB = 0;
        maker.isParticipant = false;

        LibDerivativeStorage.removeCommunityAuction(positionKey, auctionId);
        LibDerivativeStorage.removeCommunityAuctionMaker(auctionId, positionId);

        if (auction.totalShares == 0) {
            bool wasActive = auction.active;
            auction.active = false;
            auction.finalized = true;
            
            // Clear any remaining protocol yield bookkeeping; trackedBalance was already
            // incremented when the fees accrued, so avoid double-counting here.
            uint256 reservedA = auction.indexFeeAAccrued + auction.activeCreditFeeAAccrued;
            uint256 reservedB = auction.indexFeeBAccrued + auction.activeCreditFeeBAccrued;
            if (reservedA > 0) {
                auction.reserveA -= reservedA;
                auction.indexFeeAAccrued = 0;
                auction.activeCreditFeeAAccrued = 0;
            }
            if (reservedB > 0) {
                auction.reserveB -= reservedB;
                auction.indexFeeBAccrued = 0;
                auction.activeCreditFeeBAccrued = 0;
            }
            
            if (wasActive) {
                LibDerivativeStorage.removeCommunityAuctionGlobal(auctionId);
                LibDerivativeStorage.removeCommunityAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
                LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdA, auctionId);
                LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdB, auctionId);
            }
        }

        emit MakerLeft(auctionId, positionKey, positionId, withdrawnA, withdrawnB, feesA, feesB);
    }

    function claimFees(uint256 auctionId, uint256 positionId)
        external
        nonReentrant
        returns (uint256 feesA, uint256 feesB)
    {
        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(positionId);
        DerivativeTypes.MakerPosition storage maker =
            LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
        if (!maker.isParticipant || maker.share == 0) {
            revert CommunityAuction_NotParticipant(positionKey);
        }

        (feesA, feesB) = LibCommunityAuctionFeeIndex.settleMaker(auctionId, positionKey);
        if (feesA > 0 || feesB > 0) {
            LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
            DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
            Types.PoolData storage poolA = LibAppStorage.s().pools[auction.poolIdA];
            Types.PoolData storage poolB = LibAppStorage.s().pools[auction.poolIdB];
            _backSettledMakerFees(auction, poolA, poolB, feesA, feesB);
        }
        emit FeesClaimed(auctionId, positionKey, feesA, feesB);
    }

    function finalizeAuction(uint256 auctionId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        if (!auction.active) revert CommunityAuction_NotActive(auctionId);
        if (auction.finalized) revert CommunityAuction_AlreadyFinalized(auctionId);
        if (block.timestamp < auction.endTime) revert CommunityAuction_NotExpired(auctionId);

        auction.active = false;
        auction.finalized = true;
        LibDerivativeStorage.removeCommunityAuctionGlobal(auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdA, auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdB, auctionId);

        emit CommunityAuctionFinalized(auctionId, auction.creatorPositionKey, auction.reserveA, auction.reserveB);
    }

    function cancelCommunityAuction(uint256 auctionId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        if (!auction.active) revert CommunityAuction_NotActive(auctionId);
        if (auction.finalized) revert CommunityAuction_AlreadyFinalized(auctionId);
        if (block.timestamp >= auction.startTime) revert CommunityAuction_AlreadyStarted(auctionId);

        PositionNFT nft = LibDirectHelpers._positionNFT();
        address owner = nft.ownerOf(auction.creatorPositionId);
        if (
            msg.sender != owner &&
            nft.getApproved(auction.creatorPositionId) != msg.sender &&
            !nft.isApprovedForAll(owner, msg.sender)
        ) {
            revert CommunityAuction_NotCreator(auction.creatorPositionKey);
        }

        auction.active = false;
        auction.finalized = true;
        LibDerivativeStorage.removeCommunityAuctionGlobal(auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdA, auctionId);
        LibDerivativeStorage.removeCommunityAuctionByPool(auction.poolIdB, auctionId);

        emit CommunityAuctionCancelled(auctionId, auction.creatorPositionKey, auction.reserveA, auction.reserveB);
    }

    function getCommunityAuction(uint256 auctionId) external view returns (DerivativeTypes.CommunityAuction memory) {
        return LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
    }

    function getMakerShare(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (uint256 share, uint256 pendingFeesA, uint256 pendingFeesB)
    {
        DerivativeTypes.MakerPosition storage maker =
            LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
        share = maker.share;
        (pendingFeesA, pendingFeesB) = LibCommunityAuctionFeeIndex.pendingFees(auctionId, positionKey);
    }

    function previewJoin(uint256 auctionId, uint256 amountA) external view returns (uint256 requiredB) {
        if (amountA == 0) return 0;
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        if (auction.reserveA == 0 || auction.reserveB == 0) {
            return 0;
        }
        requiredB = Math.mulDiv(amountA, auction.reserveB, auction.reserveA);
    }

    function previewCommunitySwap(uint256 auctionId, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        if (amountIn == 0) return (0, 0);
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        if (
            !auction.active || auction.finalized || auction.totalShares == 0 || block.timestamp < auction.startTime
                || block.timestamp >= auction.endTime
        ) {
            return (0, 0);
        }
        bool inIsA;
        if (tokenIn == auction.tokenA) {
            inIsA = true;
        } else if (tokenIn == auction.tokenB) {
            inIsA = false;
        } else {
            return (0, 0);
        }
        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 reserveOut = inIsA ? auction.reserveB : auction.reserveA;
        (uint256 rawOut, uint256 fee, uint256 outToRecipient) =
            LibAuctionSwap.computeSwap(auction.feeAsset, reserveIn, reserveOut, amountIn, auction.feeBps);
        rawOut;
        feeAmount = fee;
        amountOut = outToRecipient;
    }

    function previewLeave(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB)
    {
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        DerivativeTypes.MakerPosition storage maker =
            LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
        if (auction.totalShares == 0 || maker.share == 0) {
            return (0, 0, 0, 0);
        }
        // Calculate withdrawal excluding protocol yield (FI + ACI) backing yieldReserve
        uint256 reservedA = auction.indexFeeAAccrued + auction.activeCreditFeeAAccrued;
        uint256 reservedB = auction.indexFeeBAccrued + auction.activeCreditFeeBAccrued;
        uint256 withdrawableReserveA = auction.reserveA > reservedA ? auction.reserveA - reservedA : 0;
        uint256 withdrawableReserveB = auction.reserveB > reservedB ? auction.reserveB - reservedB : 0;
        withdrawA = Math.mulDiv(withdrawableReserveA, maker.share, auction.totalShares);
        withdrawB = Math.mulDiv(withdrawableReserveB, maker.share, auction.totalShares);
        (feesA, feesB) = LibCommunityAuctionFeeIndex.pendingFees(auctionId, positionKey);
    }

    function getTotalMakers(uint256 auctionId) external view returns (uint256) {
        return LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId].makerCount;
    }

    function joinCommunityAuction(uint256 auctionId, uint256 positionId, uint256 amountA, uint256 amountB)
        external
        nonReentrant
    {
        if (amountA == 0 || amountB == 0) {
            revert CommunityAuction_InvalidAmount(amountA == 0 ? amountA : amountB);
        }
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        if (ds.communityAuctionPaused) revert CommunityAuction_Paused();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        _requireJoinActive(auctionId, auction);

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(positionId);
        LibDirectHelpers._pool(auction.poolIdA);
        LibDirectHelpers._pool(auction.poolIdB);

        if (!LibPoolMembership.isMember(positionKey, auction.poolIdA)) {
            revert PoolMembershipRequired(positionKey, auction.poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, auction.poolIdB)) {
            revert PoolMembershipRequired(positionKey, auction.poolIdB);
        }

        DerivativeTypes.MakerPosition storage maker = ds.communityAuctionMakers[auctionId][positionKey];
        bool newParticipant = !maker.isParticipant;

        _validateJoinRatio(auction, amountA, amountB);

        // If already participating, settle pending fees before changing share to avoid losing accruals.
        if (!newParticipant) {
            LibCommunityAuctionFeeIndex.settleMaker(auctionId, positionKey);
        }

        LibFeeIndex.settle(auction.poolIdA, positionKey);
        LibActiveCreditIndex.settle(auction.poolIdA, positionKey);
        LibFeeIndex.settle(auction.poolIdB, positionKey);
        LibActiveCreditIndex.settle(auction.poolIdB, positionKey);

        LibDerivativeHelpers._lockAmmReserves(positionKey, auction.poolIdA, amountA);
        LibDerivativeHelpers._lockAmmReserves(positionKey, auction.poolIdB, amountB);

        uint256 share = Math.sqrt(Math.mulDiv(amountA, amountB, 1));

        maker.share += share;
        maker.initialContributionA += amountA;
        maker.initialContributionB += amountB;
        maker.isParticipant = true;

        auction.totalShares += share;
        if (newParticipant) {
            auction.makerCount += 1;
        }
        auction.reserveA += amountA;
        auction.reserveB += amountB;

        if (newParticipant) {
            LibDerivativeStorage.addCommunityAuction(positionKey, auctionId);
            LibDerivativeStorage.addCommunityAuctionMaker(auctionId, positionId);
        }

        LibCommunityAuctionFeeIndex.snapshotIndexes(auctionId, positionKey);

        emit MakerJoined(auctionId, positionKey, positionId, amountA, amountB, share);
    }

    function swapExactIn(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert CommunityAuction_InvalidAmount(amountIn);
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.CommunityAuction storage auction = ds.communityAuctions[auctionId];
        _requireSwapActive(auctionId, auction);

        bool inIsA;
        if (tokenIn == auction.tokenA) {
            inIsA = true;
        } else if (tokenIn == auction.tokenB) {
            inIsA = false;
        } else {
            revert CommunityAuction_InvalidToken(tokenIn);
        }

        Types.PoolData storage poolA = LibAppStorage.s().pools[auction.poolIdA];
        Types.PoolData storage poolB = LibAppStorage.s().pools[auction.poolIdB];

        LibCurrency.assertMsgValue(tokenIn, amountIn);
        address tokenOut = inIsA ? auction.tokenB : auction.tokenA;
        uint256 actualIn = LibCurrency.pull(tokenIn, msg.sender, amountIn);
        if (actualIn == 0) revert CommunityAuction_InvalidAmount(actualIn);

        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 reserveOut = inIsA ? auction.reserveB : auction.reserveA;
        TransientSwapCache.cacheReserves(reserveIn, reserveOut);

        (uint256 rawOut, uint256 feeAmount, uint256 outputToRecipient) =
            LibAuctionSwap.computeSwap(auction.feeAsset, reserveIn, reserveOut, actualIn, auction.feeBps);
        rawOut;

        amountOut = outputToRecipient;
        if (amountOut < minOut) revert CommunityAuction_Slippage(minOut, amountOut);

        uint256 makerFee;
        uint256 protocolFee;
        uint256 treasuryShare;
        if (feeAmount > 0) {
            uint16 makerShareBps = ds.config.communityMakerShareBps;
            makerFee = Math.mulDiv(feeAmount, makerShareBps, 10_000);
            protocolFee = feeAmount - makerFee;
            (treasuryShare,,) = LibFeeRouter.previewSplit(protocolFee);
        }

        uint256 newReserveIn = reserveIn + actualIn;
        uint256 newReserveOut = reserveOut - outputToRecipient;
        if (treasuryShare > 0) {
            bool ok;
            (newReserveIn, newReserveOut, ok) =
                LibAuctionSwap.applyProtocolFee(auction.feeAsset, newReserveIn, newReserveOut, treasuryShare);
            if (!ok) {
                revert CommunityAuction_InvalidAmount(treasuryShare);
            }
        }

        if (inIsA) {
            auction.reserveA = newReserveIn;
            auction.reserveB = newReserveOut;
        } else {
            auction.reserveB = newReserveIn;
            auction.reserveA = newReserveOut;
        }

        if (makerFee > 0) {
            address makerFeeToken = auction.feeAsset == DerivativeTypes.FeeAsset.TokenIn ? tokenIn : tokenOut;
            if (makerFeeToken == auction.tokenA) {
                LibCommunityAuctionFeeIndex.accrueTokenAFee(auctionId, makerFee);
            } else {
                LibCommunityAuctionFeeIndex.accrueTokenBFee(auctionId, makerFee);
            }
        }

        if (protocolFee > 0) {
            uint256 feePoolId;
            address feeToken;
            if (auction.feeAsset == DerivativeTypes.FeeAsset.TokenIn) {
                feePoolId = inIsA ? auction.poolIdA : auction.poolIdB;
                feeToken = tokenIn;
            } else {
                feePoolId = inIsA ? auction.poolIdB : auction.poolIdA;
                feeToken = tokenOut;
            }
            TransientSwapCache.cacheFeePool(feePoolId);
            uint256 cachedFeePoolId = TransientSwapCache.loadFeePool();
            if (cachedFeePoolId != 0) {
                feePoolId = cachedFeePoolId;
            }

            uint256 extraBacking = feePoolId == auction.poolIdA ? auction.reserveA : auction.reserveB;
            (uint256 toTreasury, uint256 toActive, uint256 toIndex) =
                LibFeeRouter.routeSamePool(feePoolId, protocolFee, COMMUNITY_FEE_SOURCE, false, extraBacking);

            if (toTreasury > 0) {
                LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[feePoolId] += toTreasury;
                if (feeToken == auction.tokenA) {
                    auction.treasuryFeeAAccrued += toTreasury;
                } else {
                    auction.treasuryFeeBAccrued += toTreasury;
                }
            }
            if (toIndex > 0 || toActive > 0) {
                // Reflect protocol fees in pool backing so trackedBalance stays aligned with yieldReserve.
                Types.PoolData storage feePool = feePoolId == auction.poolIdA ? poolA : poolB;
                feePool.trackedBalance += toIndex + toActive;
                if (LibCurrency.isNative(feePool.underlying)) {
                    LibAppStorage.s().nativeTrackedTotal += toIndex + toActive;
                }
                if (feePoolId == auction.poolIdA) {
                    auction.indexFeeAAccrued += toIndex;
                    auction.activeCreditFeeAAccrued += toActive;
                } else {
                    auction.indexFeeBAccrued += toIndex;
                    auction.activeCreditFeeBAccrued += toActive;
                }
            }
        }

        LibCurrency.transfer(tokenOut, recipient, outputToRecipient);
        if (LibCurrency.isNative(tokenOut) && outputToRecipient > 0) {
            LibAppStorage.s().nativeTrackedTotal -= outputToRecipient;
        }

        emit CommunityAuctionSwapped(
            auctionId,
            msg.sender,
            tokenIn,
            actualIn,
            outputToRecipient,
            feeAmount,
            recipient
        );
    }

    function _requireJoinActive(uint256 auctionId, DerivativeTypes.CommunityAuction storage auction) internal view {
        if (!auction.active) revert CommunityAuction_NotActive(auctionId);
        if (auction.finalized) revert CommunityAuction_AlreadyFinalized(auctionId);
        if (block.timestamp >= auction.endTime) revert CommunityAuction_NotActive(auctionId);
    }

    function _requireSwapActive(uint256 auctionId, DerivativeTypes.CommunityAuction storage auction) internal view {
        if (!auction.active) revert CommunityAuction_NotActive(auctionId);
        if (auction.finalized) revert CommunityAuction_AlreadyFinalized(auctionId);
        if (auction.totalShares == 0) revert CommunityAuction_NotActive(auctionId);
        if (block.timestamp < auction.startTime) revert CommunityAuction_NotActive(auctionId);
        if (block.timestamp >= auction.endTime) revert CommunityAuction_NotActive(auctionId);
    }

    function _validateJoinRatio(
        DerivativeTypes.CommunityAuction storage auction,
        uint256 amountA,
        uint256 amountB
    ) internal view {
        if (auction.reserveA == 0 || auction.reserveB == 0) {
            revert CommunityAuction_InvalidAmount(auction.reserveA == 0 ? auction.reserveA : auction.reserveB);
        }
        uint256 expectedB = Math.mulDiv(amountA, auction.reserveB, auction.reserveA);
        uint256 tolerance = expectedB / 1000;
        uint256 lower = expectedB > tolerance ? expectedB - tolerance : 0;
        if (amountB < lower || amountB > expectedB + tolerance) {
            revert CommunityAuction_InvalidRatio(expectedB, amountB);
        }
    }

    function _applyPrincipalDelta(
        uint256 pid,
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 currentReserve,
        uint256 initialReserve
    ) internal {
        if (currentReserve == initialReserve) return;

        // Ensure fresh index checkpoints before principal changes.
        LibFeeIndex.settle(pid, positionKey);

        if (currentReserve > initialReserve) {
            uint256 delta = currentReserve - initialReserve;
            pool.userPrincipal[positionKey] += delta;
            pool.totalDeposits += delta;
            pool.trackedBalance += delta;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += delta;
            }
        } else {
            uint256 delta = initialReserve - currentReserve;
            uint256 principal = pool.userPrincipal[positionKey];
            if (principal < delta) revert InsufficientPrincipal(delta, principal);
            pool.userPrincipal[positionKey] = principal - delta;
            pool.totalDeposits -= delta;
            if (pool.trackedBalance < delta) revert InsufficientPrincipal(delta, pool.trackedBalance);
            pool.trackedBalance -= delta;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= delta;
            }
        }
    }

    /// @dev Move maker fee accruals into pool backing by carving them out of auction reserves.
    function _backSettledMakerFees(
        DerivativeTypes.CommunityAuction storage auction,
        Types.PoolData storage poolA,
        Types.PoolData storage poolB,
        uint256 feesA,
        uint256 feesB
    ) internal {
        if (feesA > 0) {
            if (auction.reserveA < feesA) revert CommunityAuction_InvalidAmount(feesA);
            auction.reserveA -= feesA;
            // Reclassify maker fees from auction reserves into pool backing: userAccruedYield
            // was credited in settleMaker, so move the tokens into yieldReserve and trackedBalance.
            poolA.yieldReserve += feesA;
            poolA.trackedBalance += feesA;
            if (LibCurrency.isNative(poolA.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += feesA;
            }
        }
        if (feesB > 0) {
            if (auction.reserveB < feesB) revert CommunityAuction_InvalidAmount(feesB);
            auction.reserveB -= feesB;
            // Reclassify maker fees from auction reserves into pool backing for token B.
            poolB.yieldReserve += feesB;
            poolB.trackedBalance += feesB;
            if (LibCurrency.isNative(poolB.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += feesB;
            }
        }
    }
}

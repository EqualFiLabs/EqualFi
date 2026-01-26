// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibAuctionSwap} from "../libraries/LibAuctionSwap.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {PoolMembershipRequired, InsufficientPrincipal} from "../libraries/Errors.sol";
import {TransientSwapCache} from "../libraries/TransientSwapCache.sol";

error AmmAuction_InvalidToken(address token);
error AmmAuction_InvalidPool(uint256 poolId);
error AmmAuction_InvalidAmount(uint256 amount);
error AmmAuction_InvalidFee(uint16 feeBps, uint16 maxFeeBps);
error AmmAuction_Paused();
error AmmAuction_NotActive(uint256 auctionId);
error AmmAuction_AlreadyFinalized(uint256 auctionId);
error AmmAuction_NotExpired(uint256 auctionId);
error AmmAuction_Expired(uint256 auctionId);
error AmmAuction_Slippage(uint256 minOut, uint256 actualOut);
error AmmAuction_NotMaker(address caller, uint256 positionId);
error AmmAuction_InvalidRatio(uint256 expectedB, uint256 actualB);

/// @notice AMM auction facet using Position NFT collateral
contract AmmAuctionFacet is ReentrancyGuardModifiers {
    bytes32 internal constant AMM_FEE_SOURCE = keccak256("AMM_AUCTION_FEE");

    event AuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
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

    event AuctionSwapped(
        uint256 indexed auctionId,
        address indexed swapper,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );

    event AuctionFinalized(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 reserveA,
        uint256 reserveB,
        uint256 makerFeeA,
        uint256 makerFeeB
    );

    event AuctionCancelled(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 reserveA,
        uint256 reserveB,
        uint256 makerFeeA,
        uint256 makerFeeB
    );

    event AuctionLiquidityAdded(
        uint256 indexed auctionId,
        bytes32 indexed makerPositionKey,
        uint256 amountA,
        uint256 amountB,
        uint256 reserveA,
        uint256 reserveB
    );

    event AmmPausedUpdated(bool paused);

    function setAmmPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDerivativeStorage.derivativeStorage().ammPaused = paused;
        emit AmmPausedUpdated(paused);
    }

    function createAuction(DerivativeTypes.CreateAuctionParams calldata params)
        external
        nonReentrant
        returns (uint256 auctionId)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        if (ds.ammPaused) revert AmmAuction_Paused();
        if (params.reserveA == 0 || params.reserveB == 0) {
            revert AmmAuction_InvalidAmount(params.reserveA == 0 ? params.reserveA : params.reserveB);
        }
        if (params.poolIdA == params.poolIdB) revert AmmAuction_InvalidPool(params.poolIdA);
        LibDerivativeHelpers._validateTimeWindow(params.startTime, params.endTime);

        if (ds.config.maxFeeBps != 0 && params.feeBps > ds.config.maxFeeBps) {
            revert AmmAuction_InvalidFee(params.feeBps, ds.config.maxFeeBps);
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

        auctionId = ++ds.nextAuctionId;
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        auction.makerPositionKey = positionKey;
        auction.makerPositionId = params.positionId;
        auction.poolIdA = params.poolIdA;
        auction.poolIdB = params.poolIdB;
        auction.tokenA = poolA.underlying;
        auction.tokenB = poolB.underlying;
        auction.reserveA = params.reserveA;
        auction.reserveB = params.reserveB;
        auction.initialReserveA = params.reserveA;
        auction.initialReserveB = params.reserveB;
        auction.invariant = Math.mulDiv(params.reserveA, params.reserveB, 1);
        auction.startTime = params.startTime;
        auction.endTime = params.endTime;
        auction.feeBps = params.feeBps;
        auction.feeAsset = params.feeAsset;
        auction.active = true;
        auction.finalized = false;

        LibDerivativeStorage.addAuction(positionKey, auctionId);
        LibDerivativeStorage.addAuctionGlobal(auctionId);
        LibDerivativeStorage.addAuctionByPool(auction.poolIdA, auctionId);
        LibDerivativeStorage.addAuctionByPool(auction.poolIdB, auctionId);
        LibDerivativeStorage.addAuctionByToken(auction.tokenA, auctionId);
        if (auction.tokenB != auction.tokenA) {
            LibDerivativeStorage.addAuctionByToken(auction.tokenB, auctionId);
        }
        LibDerivativeStorage.addAuctionByPair(auction.tokenA, auction.tokenB, auctionId);

        emit AuctionCreated(
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

    function swapExactIn(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _swapExactInInternal(auctionId, tokenIn, amountIn, minOut, recipient);
    }

    function swapExactInOrFinalize(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut, bool finalized) {
        if (amountIn == 0) revert AmmAuction_InvalidAmount(amountIn);
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        _requireActive(auctionId, auction);

        if (block.timestamp >= auction.endTime) {
            _closeAuction(auctionId, auction, false);
            return (0, true);
        }
        if (block.timestamp < auction.startTime) revert AmmAuction_NotActive(auctionId);

        amountOut = _swapExactInInternal(auctionId, tokenIn, amountIn, minOut, recipient);
        return (amountOut, false);
    }

    function _swapExactInInternal(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        _requireActive(auctionId, auction);

        if (block.timestamp < auction.startTime) revert AmmAuction_NotActive(auctionId);
        if (block.timestamp >= auction.endTime) revert AmmAuction_Expired(auctionId);

        uint256 poolIdA = auction.poolIdA;
        uint256 poolIdB = auction.poolIdB;
        address tokenA = auction.tokenA;
        address tokenB = auction.tokenB;
        DerivativeTypes.FeeAsset feeAsset = auction.feeAsset;

        bool inIsA;
        if (tokenIn == tokenA) {
            inIsA = true;
        } else if (tokenIn == tokenB) {
            inIsA = false;
        } else {
            revert AmmAuction_InvalidToken(tokenIn);
        }

        Types.PoolData storage poolA = LibAppStorage.s().pools[poolIdA];
        Types.PoolData storage poolB = LibAppStorage.s().pools[poolIdB];

        LibCurrency.assertMsgValue(tokenIn, amountIn);
        address tokenOut = inIsA ? tokenB : tokenA;
        uint256 actualIn = LibCurrency.pull(tokenIn, msg.sender, amountIn);
        if (actualIn == 0) revert AmmAuction_InvalidAmount(actualIn);

        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 reserveOut = inIsA ? auction.reserveB : auction.reserveA;
        TransientSwapCache.cacheReserves(reserveIn, reserveOut);

        (uint256 rawOut, uint256 feeAmount, uint256 outputToRecipient) =
            LibAuctionSwap.computeSwap(auction.feeAsset, reserveIn, reserveOut, actualIn, auction.feeBps);
        rawOut;

        amountOut = outputToRecipient;
        if (amountOut < minOut) revert AmmAuction_Slippage(minOut, amountOut);

        uint256 makerFee;
        uint256 protocolFee;
        uint256 treasuryShare;
        if (feeAmount > 0) {
            uint16 makerShareBps = ds.config.ammMakerShareBps;
            makerFee = Math.mulDiv(feeAmount, makerShareBps, 10_000);
            protocolFee = feeAmount - makerFee;
            (treasuryShare,,) = LibFeeRouter.previewSplit(protocolFee);
        }

        uint256 newReserveIn = reserveIn + actualIn;
        uint256 newReserveOut = reserveOut - outputToRecipient;
        if (treasuryShare > 0) {
            bool ok;
            (newReserveIn, newReserveOut, ok) =
                LibAuctionSwap.applyProtocolFee(feeAsset, newReserveIn, newReserveOut, treasuryShare);
            if (!ok) {
                uint256 available = feeAsset == DerivativeTypes.FeeAsset.TokenIn
                    ? newReserveIn
                    : newReserveOut;
                revert InsufficientPrincipal(treasuryShare, available);
            }
        }

        uint256 feePoolId;
        if (inIsA) {
            _applyReserveDelta(auction.makerPositionKey, poolIdA, auction.reserveA, newReserveIn);
            _applyReserveDelta(auction.makerPositionKey, poolIdB, auction.reserveB, newReserveOut);
            auction.reserveA = newReserveIn;
            auction.reserveB = newReserveOut;
        } else {
            _applyReserveDelta(auction.makerPositionKey, poolIdB, auction.reserveB, newReserveIn);
            _applyReserveDelta(auction.makerPositionKey, poolIdA, auction.reserveA, newReserveOut);
            auction.reserveB = newReserveIn;
            auction.reserveA = newReserveOut;
        }

        _accrueMakerFee(auction, auction.feeAsset == DerivativeTypes.FeeAsset.TokenIn ? tokenIn : tokenOut, makerFee);

        if (protocolFee > 0) {
            address feeToken;
            if (feeAsset == DerivativeTypes.FeeAsset.TokenIn) {
                feePoolId = inIsA ? poolIdA : poolIdB;
                feeToken = tokenIn;
            } else {
                feePoolId = inIsA ? poolIdB : poolIdA;
                feeToken = tokenOut;
            }
            TransientSwapCache.cacheFeePool(feePoolId);
            uint256 cachedFeePoolId = TransientSwapCache.loadFeePool();
            if (cachedFeePoolId != 0) {
                feePoolId = cachedFeePoolId;
            }

            uint256 extraBacking = feePoolId == poolIdA ? auction.reserveA : auction.reserveB;
            (uint256 toTreasury, uint256 toActive, uint256 toIndex) =
                LibFeeRouter.routeSamePool(feePoolId, protocolFee, AMM_FEE_SOURCE, false, extraBacking);
            if (toTreasury > 0) {
                LibDerivativeStorage.derivativeStorage().treasuryFeesByPool[feePoolId] += toTreasury;
                _accrueTreasuryFee(auction, feeToken, toTreasury);
            }
            if (toIndex > 0) {
                if (feePoolId == auction.poolIdA) {
                    ds.indexFeeAByAuction[auctionId] += toIndex;
                } else {
                    ds.indexFeeBByAuction[auctionId] += toIndex;
                }
            }
            if (toActive > 0) {
                if (feePoolId == auction.poolIdA) {
                    ds.activeCreditFeeAByAuction[auctionId] += toActive;
                } else {
                    ds.activeCreditFeeBByAuction[auctionId] += toActive;
                }
            }
        }

        LibCurrency.transfer(tokenOut, recipient, outputToRecipient);
        if (LibCurrency.isNative(tokenOut) && outputToRecipient > 0) {
            LibAppStorage.s().nativeTrackedTotal -= outputToRecipient;
        }

        emit AuctionSwapped(
            auctionId,
            msg.sender,
            tokenIn,
            actualIn,
            outputToRecipient,
            feeAmount,
            recipient
        );
    }

    function finalizeAuction(uint256 auctionId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        _requireActive(auctionId, auction);
        if (block.timestamp < auction.endTime) revert AmmAuction_NotExpired(auctionId);
        _closeAuction(auctionId, auction, false);
    }

    function cancelAuction(uint256 auctionId) external nonReentrant {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        _requireActive(auctionId, auction);
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, auction.makerPositionId);
        _closeAuction(auctionId, auction, true);
    }

    function addLiquidity(uint256 auctionId, uint256 amountA, uint256 amountB) external nonReentrant {
        if (amountA == 0 || amountB == 0) {
            revert AmmAuction_InvalidAmount(amountA == 0 ? amountA : amountB);
        }
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        _requireActive(auctionId, auction);
        if (block.timestamp < auction.startTime) revert AmmAuction_NotActive(auctionId);
        if (block.timestamp >= auction.endTime) revert AmmAuction_Expired(auctionId);

        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, auction.makerPositionId);

        if (!LibPoolMembership.isMember(auction.makerPositionKey, auction.poolIdA)) {
            revert PoolMembershipRequired(auction.makerPositionKey, auction.poolIdA);
        }
        if (!LibPoolMembership.isMember(auction.makerPositionKey, auction.poolIdB)) {
            revert PoolMembershipRequired(auction.makerPositionKey, auction.poolIdB);
        }

        _validateAddRatio(auction, amountA, amountB);

        LibFeeIndex.settle(auction.poolIdA, auction.makerPositionKey);
        LibActiveCreditIndex.settle(auction.poolIdA, auction.makerPositionKey);
        LibFeeIndex.settle(auction.poolIdB, auction.makerPositionKey);
        LibActiveCreditIndex.settle(auction.poolIdB, auction.makerPositionKey);

        LibDerivativeHelpers._lockAmmReserves(auction.makerPositionKey, auction.poolIdA, amountA);
        LibDerivativeHelpers._lockAmmReserves(auction.makerPositionKey, auction.poolIdB, amountB);

        auction.reserveA += amountA;
        auction.reserveB += amountB;
        auction.initialReserveA += amountA;
        auction.initialReserveB += amountB;
        auction.invariant = Math.mulDiv(auction.reserveA, auction.reserveB, 1);

        emit AuctionLiquidityAdded(
            auctionId,
            auction.makerPositionKey,
            amountA,
            amountB,
            auction.reserveA,
            auction.reserveB
        );
    }

    function getAuction(uint256 auctionId) external view returns (DerivativeTypes.AmmAuction memory) {
        return LibDerivativeStorage.derivativeStorage().auctions[auctionId];
    }

    function previewSwap(uint256 auctionId, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        if (!auction.active || auction.finalized) {
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

    function getAuctionFees(uint256 auctionId) external view returns (uint256 makerFeeA, uint256 makerFeeB) {
        DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
        return (auction.makerFeeAAccrued, auction.makerFeeBAccrued);
    }

    function _applyReserveDelta(bytes32 positionKey, uint256 poolId, uint256 oldReserve, uint256 newReserve) internal {
        if (newReserve == oldReserve) return;
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        if (newReserve > oldReserve) {
            enc.directLent += newReserve - oldReserve;
        } else {
            uint256 delta = oldReserve - newReserve;
            uint256 current = enc.directLent;
            if (current < delta) {
                revert InsufficientPrincipal(delta, current);
            }
            enc.directLent = current - delta;
        }
    }

    function _accrueMakerFee(DerivativeTypes.AmmAuction storage auction, address feeToken, uint256 makerFee) internal {
        if (makerFee == 0) return;
        if (feeToken == auction.tokenA) {
            auction.makerFeeAAccrued += makerFee;
        } else {
            auction.makerFeeBAccrued += makerFee;
        }
    }

    function _accrueTreasuryFee(
        DerivativeTypes.AmmAuction storage auction,
        address feeToken,
        uint256 treasuryFee
    ) internal {
        if (treasuryFee == 0) return;
        if (feeToken == auction.tokenA) {
            auction.treasuryFeeAAccrued += treasuryFee;
        } else {
            auction.treasuryFeeBAccrued += treasuryFee;
        }
    }

    function _requireActive(uint256 auctionId, DerivativeTypes.AmmAuction storage auction) internal view {
        if (!auction.active) revert AmmAuction_NotActive(auctionId);
        if (auction.finalized) revert AmmAuction_AlreadyFinalized(auctionId);
    }

    function _validateAddRatio(DerivativeTypes.AmmAuction storage auction, uint256 amountA, uint256 amountB)
        internal
        view
    {
        if (auction.reserveA == 0 || auction.reserveB == 0) {
            revert AmmAuction_InvalidAmount(auction.reserveA == 0 ? auction.reserveA : auction.reserveB);
        }
        uint256 expectedB = Math.mulDiv(amountA, auction.reserveB, auction.reserveA);
        uint256 tolerance = expectedB / 1000;
        uint256 lower = expectedB > tolerance ? expectedB - tolerance : 0;
        if (amountB < lower || amountB > expectedB + tolerance) {
            revert AmmAuction_InvalidRatio(expectedB, amountB);
        }
    }

    function _closeAuction(uint256 auctionId, DerivativeTypes.AmmAuction storage auction, bool cancelled) internal {
        auction.active = false;
        auction.finalized = true;

        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        Types.PoolData storage poolA = LibAppStorage.s().pools[auction.poolIdA];
        Types.PoolData storage poolB = LibAppStorage.s().pools[auction.poolIdB];

        LibActiveCreditIndex.settle(auction.poolIdA, auction.makerPositionKey);
        LibActiveCreditIndex.settle(auction.poolIdB, auction.makerPositionKey);

        LibDerivativeHelpers._unlockAmmReserves(auction.makerPositionKey, auction.poolIdA, auction.reserveA);
        LibDerivativeHelpers._unlockAmmReserves(auction.makerPositionKey, auction.poolIdB, auction.reserveB);
        LibActiveCreditIndex.applyEncumbranceDecrease(
            poolA, auction.poolIdA, auction.makerPositionKey, auction.initialReserveA
        );
        LibActiveCreditIndex.applyEncumbranceDecrease(
            poolB, auction.poolIdB, auction.makerPositionKey, auction.initialReserveB
        );

        uint256 reserveAForPrincipal = auction.reserveA;
        uint256 reserveBForPrincipal = auction.reserveB;

        uint256 indexFeeA = ds.indexFeeAByAuction[auctionId];
        uint256 indexFeeB = ds.indexFeeBByAuction[auctionId];
        uint256 activeCreditFeeA = ds.activeCreditFeeAByAuction[auctionId];
        uint256 activeCreditFeeB = ds.activeCreditFeeBByAuction[auctionId];

        uint256 protocolYieldA = indexFeeA + activeCreditFeeA;
        if (protocolYieldA > 0) {
            // Reconcile encumbered reserves into pool backing on close.
            poolA.trackedBalance += protocolYieldA;
            if (LibCurrency.isNative(poolA.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += protocolYieldA;
            }
        }
        uint256 protocolYieldB = indexFeeB + activeCreditFeeB;
        if (protocolYieldB > 0) {
            poolB.trackedBalance += protocolYieldB;
            if (LibCurrency.isNative(poolB.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += protocolYieldB;
            }
        }

        if (indexFeeA > 0 && reserveAForPrincipal >= indexFeeA) {
            reserveAForPrincipal -= indexFeeA;
        }
        if (indexFeeB > 0 && reserveBForPrincipal >= indexFeeB) {
            reserveBForPrincipal -= indexFeeB;
        }
        if (activeCreditFeeA > 0 && reserveAForPrincipal >= activeCreditFeeA) {
            reserveAForPrincipal -= activeCreditFeeA;
        }
        if (activeCreditFeeB > 0 && reserveBForPrincipal >= activeCreditFeeB) {
            reserveBForPrincipal -= activeCreditFeeB;
        }

        _applyPrincipalDelta(
            auction.poolIdA, poolA, auction.makerPositionKey, reserveAForPrincipal, auction.initialReserveA
        );
        _applyPrincipalDelta(
            auction.poolIdB, poolB, auction.makerPositionKey, reserveBForPrincipal, auction.initialReserveB
        );

        LibDerivativeStorage.removeAuction(auction.makerPositionKey, auctionId);
        LibDerivativeStorage.removeAuctionGlobal(auctionId);
        LibDerivativeStorage.removeAuctionByPool(auction.poolIdA, auctionId);
        LibDerivativeStorage.removeAuctionByPool(auction.poolIdB, auctionId);
        LibDerivativeStorage.removeAuctionByToken(auction.tokenA, auctionId);
        if (auction.tokenB != auction.tokenA) {
            LibDerivativeStorage.removeAuctionByToken(auction.tokenB, auctionId);
        }
        LibDerivativeStorage.removeAuctionByPair(auction.tokenA, auction.tokenB, auctionId);
        ds.indexFeeAByAuction[auctionId] = 0;
        ds.indexFeeBByAuction[auctionId] = 0;
        ds.activeCreditFeeAByAuction[auctionId] = 0;
        ds.activeCreditFeeBByAuction[auctionId] = 0;

        if (cancelled) {
            emit AuctionCancelled(
                auctionId,
                auction.makerPositionKey,
                auction.reserveA,
                auction.reserveB,
                auction.makerFeeAAccrued,
                auction.makerFeeBAccrued
            );
        } else {
            emit AuctionFinalized(
                auctionId,
                auction.makerPositionKey,
                auction.reserveA,
                auction.reserveB,
                auction.makerFeeAAccrued,
                auction.makerFeeBAccrued
            );
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

        // Prevent new principal from inheriting old fee/maintenance deltas.
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
            // trackedBalance represents actual backing; ensure it tracks principal reduction.
            if (pool.trackedBalance < delta) revert InsufficientPrincipal(delta, pool.trackedBalance);
            pool.trackedBalance -= delta;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= delta;
            }
        }
    }

}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {LibReentrancyGuard, ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibClAuctionStorage} from "../libraries/LibClAuctionStorage.sol";
import {LibClMath} from "../libraries/LibClMath.sol";
import {LibClTickBitmap} from "../libraries/LibClTickBitmap.sol";
import {LibClPosition} from "../libraries/LibClPosition.sol";
import {LibClSwap} from "../libraries/LibClSwap.sol";
import {LibClEncumbranceBridge} from "../libraries/LibClEncumbranceBridge.sol";
import {
    ClAuction_NotActive,
    ClAuction_InvalidTickRange,
    ClAuction_InvalidTickSpacing,
    ClAuction_InvalidSqrtPrice,
    ClAuction_Slippage,
    ClAuction_Unauthorized,
    ClAuction_InsufficientPrincipal,
    ClAuction_PositionNotClear,
    ClAuction_Paused,
    ClAuction_CreationDisabled,
    ClAuction_AlreadyFinalized,
    ClAuction_InvalidTimeWindow,
    ClAuction_TBADeploymentFailed,
    ClAuction_InputAmountMismatch,
    ClAuction_InvalidSwapFee,
    ClAuction_InvalidToken,
    ClAuction_InvalidAmount,
    ClAuction_LiquidityUnderflow
} from "../libraries/ClAuctionErrors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {ClPositionManager} from "../nft/ClPositionManager.sol";
import {Types} from "../libraries/Types.sol";

/// @notice Mutating facet for concentrated-liquidity community auctions.
contract ClCommunityAuctionFacet is ReentrancyGuardModifiers {
    bytes32 internal constant CL_FEE_SOURCE = keccak256("CL_COMMUNITY_AUCTION_FEE");

    event ClCommunityAuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 indexed positionId,
        uint256 poolIdA,
        uint256 poolIdB,
        address tokenA,
        address tokenB,
        uint24 tickSpacing,
        uint24 swapFee,
        uint160 sqrtPriceX96,
        int24 tick,
        uint64 startTime,
        uint64 endTime
    );

    event ClCommunityAuctionCancelled(uint256 indexed auctionId);
    event ClCommunityAuctionFinalized(uint256 indexed auctionId);

    event ClPositionMinted(
        uint256 indexed clPositionId,
        uint256 indexed auctionId,
        uint256 indexed sourcePositionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address tba
    );

    event ClLiquidityIncreased(
        uint256 indexed clPositionId,
        uint128 liquidityDelta,
        uint128 liquidityAfter,
        uint256 amount0,
        uint256 amount1
    );

    event ClLiquidityDecreased(
        uint256 indexed clPositionId,
        uint128 liquidityDelta,
        uint128 liquidityAfter,
        uint256 amount0,
        uint256 amount1
    );

    event ClFeesCollected(uint256 indexed clPositionId, uint256 amount0, uint256 amount1);
    event ClPositionBurned(uint256 indexed clPositionId);

    event ClSwap(
        uint256 indexed auctionId,
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    event ClTickCrossed(uint256 indexed auctionId, int24 tickBefore, int24 tickAfter);

    // --- Lifecycle ---

    function createClCommunityAuction(LibClAuctionStorage.CreateClAuctionParams calldata p)
        external
        nonReentrant
        returns (uint256 auctionId)
    {
        LibCurrency.assertZeroMsgValue();
        _requireAuthorized(p.positionId);

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        if (!cs.creationEnabled) revert ClAuction_CreationDisabled();
        if (!cs.allowedTickSpacings[p.tickSpacing]) revert ClAuction_InvalidTickSpacing(p.tickSpacing);

        uint24 feeCap = cs.swapFeeCap;
        if (feeCap != 0 && p.swapFee > feeCap) {
            revert ClAuction_InvalidSwapFee(p.swapFee, feeCap);
        }
        if (p.startTime >= p.endTime || p.startTime < block.timestamp) {
            revert ClAuction_InvalidTimeWindow(p.startTime, p.endTime);
        }
        if (p.sqrtPriceX96 < LibClMath.MIN_SQRT_RATIO || p.sqrtPriceX96 > LibClMath.MAX_SQRT_RATIO) {
            revert ClAuction_InvalidSqrtPrice(p.sqrtPriceX96);
        }

        Types.PoolData storage poolA = LibDirectHelpers._pool(p.poolIdA);
        Types.PoolData storage poolB = LibDirectHelpers._pool(p.poolIdB);
        if (p.poolIdA == p.poolIdB) revert ClAuction_InvalidTickSpacing(p.tickSpacing);

        int24 initialTick = LibClMath.getTickAtSqrtRatio(p.sqrtPriceX96);
        auctionId = ++cs.nextAuctionId;

        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 creatorPositionKey = LibPositionNFT.getPositionKey(address(nft), p.positionId);

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[auctionId];
        auction.auctionId = auctionId;
        auction.poolIdA = p.poolIdA;
        auction.poolIdB = p.poolIdB;
        auction.tokenA = poolA.underlying;
        auction.tokenB = poolB.underlying;
        auction.tickSpacing = p.tickSpacing;
        auction.swapFee = p.swapFee;
        auction.sqrtPriceX96 = p.sqrtPriceX96;
        auction.tick = initialTick;
        auction.startTime = p.startTime;
        auction.endTime = p.endTime;
        auction.initialized = true;
        auction.creatorPositionKey = creatorPositionKey;
        auction.creatorPositionId = p.positionId;

        emit ClCommunityAuctionCreated(
            auctionId,
            creatorPositionKey,
            p.positionId,
            p.poolIdA,
            p.poolIdB,
            poolA.underlying,
            poolB.underlying,
            p.tickSpacing,
            p.swapFee,
            p.sqrtPriceX96,
            initialTick,
            p.startTime,
            p.endTime
        );
    }

    function cancelClCommunityAuction(uint256 auctionId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibClAuctionStorage.ClCommunityAuction storage auction = LibClAuctionStorage.s().auctions[auctionId];

        if (!auction.initialized || auction.finalized || auction.cancelled) revert ClAuction_NotActive(auctionId);
        if (block.timestamp >= auction.startTime) revert ClAuction_NotActive(auctionId);
        _requireAuthorized(auction.creatorPositionId);

        auction.cancelled = true;
        emit ClCommunityAuctionCancelled(auctionId);
    }

    function finalizeClCommunityAuction(uint256 auctionId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibClAuctionStorage.ClCommunityAuction storage auction = LibClAuctionStorage.s().auctions[auctionId];

        if (!auction.initialized || auction.cancelled) revert ClAuction_NotActive(auctionId);
        if (auction.finalized) revert ClAuction_AlreadyFinalized(auctionId);
        if (block.timestamp < auction.endTime) revert ClAuction_NotActive(auctionId);

        auction.finalized = true;
        emit ClCommunityAuctionFinalized(auctionId);
    }

    // --- Liquidity ---

    function mintClPosition(LibClAuctionStorage.MintClPositionParams calldata p)
        external
        nonReentrant
        returns (uint256 clPositionId, uint128 liquidity, uint256 amountA, uint256 amountB)
    {
        LibCurrency.assertZeroMsgValue();
        _requireAuthorized(p.positionId);

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[p.auctionId];
        _requireActivePhase(auction);

        _validateTicks(p.tickLower, p.tickUpper, int24(uint24(auction.tickSpacing)));

        uint160 sqrtLowerX96 = LibClMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtUpperX96 = LibClMath.getSqrtRatioAtTick(p.tickUpper);

        liquidity = LibClMath.getLiquidityForAmounts(
            auction.sqrtPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            p.amount0Desired,
            p.amount1Desired
        );
        if (liquidity == 0) revert ClAuction_InvalidAmount(0);

        (amountA, amountB) = _amountsForLiquidity(auction.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        if (amountA < p.amount0Min) revert ClAuction_Slippage(amountA, p.amount0Min);
        if (amountB < p.amount1Min) revert ClAuction_Slippage(amountB, p.amount1Min);

        bytes32 positionKey = _positionKey(p.positionId);
        _checkAvailablePrincipal(positionKey, auction.poolIdA, amountA);
        _checkAvailablePrincipal(positionKey, auction.poolIdB, amountB);

        address tba = _ensureTBADeployed(p.positionId);

        ClPositionManager manager = ClPositionManager(cs.clPositionManager);
        clPositionId = manager.mint(tba);

        _updateTicksAndBitmap(p.auctionId, p.tickLower, p.tickUpper, _toInt128(liquidity), auction.tick);
        auction.liquidity = _addLiquidityDeltaIfInRange(
            auction.liquidity,
            auction.tick,
            p.tickLower,
            p.tickUpper,
            _toInt128(liquidity)
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = LibClPosition.getFeeGrowthInside(
            p.auctionId,
            p.tickLower,
            p.tickUpper,
            auction.tick,
            auction.feeGrowthGlobal0X128,
            auction.feeGrowthGlobal1X128
        );

        LibClAuctionStorage.ClPosition storage position = cs.positions[clPositionId];
        position.auctionId = p.auctionId;
        position.sourcePositionId = p.positionId;
        position.tickLower = p.tickLower;
        position.tickUpper = p.tickUpper;
        position.liquidity = liquidity;
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        LibClEncumbranceBridge.lock(positionKey, auction.poolIdA, amountA, auction.poolIdB, amountB, clPositionId);

        emit ClPositionMinted(clPositionId, p.auctionId, p.positionId, p.tickLower, p.tickUpper, liquidity, amountA, amountB, tba);
    }

    function increaseClLiquidity(LibClAuctionStorage.IncreaseClLiquidityParams calldata p)
        external
        nonReentrant
        returns (uint128 liquidity, uint256 amountA, uint256 amountB)
    {
        LibCurrency.assertZeroMsgValue();

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClPosition storage position = cs.positions[p.clPositionId];
        uint256 sourcePositionId = position.sourcePositionId;
        if (sourcePositionId == 0) revert ClAuction_Unauthorized(msg.sender, p.clPositionId);

        _requireAuthorized(sourcePositionId);

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[position.auctionId];
        _requireActivePhase(auction);

        uint160 sqrtLowerX96 = LibClMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtUpperX96 = LibClMath.getSqrtRatioAtTick(position.tickUpper);

        liquidity = LibClMath.getLiquidityForAmounts(
            auction.sqrtPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            p.amount0Desired,
            p.amount1Desired
        );
        if (liquidity == 0) revert ClAuction_InvalidAmount(0);

        (amountA, amountB) = _amountsForLiquidity(auction.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        if (amountA < p.amount0Min) revert ClAuction_Slippage(amountA, p.amount0Min);
        if (amountB < p.amount1Min) revert ClAuction_Slippage(amountB, p.amount1Min);

        bytes32 positionKey = _positionKey(sourcePositionId);
        _checkAvailablePrincipal(positionKey, auction.poolIdA, amountA);
        _checkAvailablePrincipal(positionKey, auction.poolIdB, amountB);

        _ensureTBADeployed(sourcePositionId);

        LibClPosition.updatePosition(p.clPositionId, _toInt128(liquidity));
        _updateTicksAndBitmap(position.auctionId, position.tickLower, position.tickUpper, _toInt128(liquidity), auction.tick);
        auction.liquidity = _addLiquidityDeltaIfInRange(
            auction.liquidity,
            auction.tick,
            position.tickLower,
            position.tickUpper,
            _toInt128(liquidity)
        );

        LibClEncumbranceBridge.lock(positionKey, auction.poolIdA, amountA, auction.poolIdB, amountB, p.clPositionId);

        emit ClLiquidityIncreased(p.clPositionId, liquidity, position.liquidity, amountA, amountB);
    }

    function decreaseClLiquidity(LibClAuctionStorage.DecreaseClLiquidityParams calldata p)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        LibCurrency.assertZeroMsgValue();

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClPosition storage position = cs.positions[p.clPositionId];
        uint256 sourcePositionId = position.sourcePositionId;
        if (sourcePositionId == 0) revert ClAuction_Unauthorized(msg.sender, p.clPositionId);

        _requireAuthorized(sourcePositionId);

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[position.auctionId];
        if (auction.cancelled) revert ClAuction_NotActive(position.auctionId);

        uint128 liquidityBefore = position.liquidity;
        if (p.liquidity == 0) revert ClAuction_InvalidAmount(0);

        uint160 sqrtLowerX96 = LibClMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtUpperX96 = LibClMath.getSqrtRatioAtTick(position.tickUpper);
        (amountA, amountB) = _amountsForLiquidity(auction.sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, p.liquidity);

        if (amountA < p.amount0Min) revert ClAuction_Slippage(amountA, p.amount0Min);
        if (amountB < p.amount1Min) revert ClAuction_Slippage(amountB, p.amount1Min);

        LibClPosition.updatePosition(p.clPositionId, -_toInt128(p.liquidity));

        _updateTicksAndBitmap(position.auctionId, position.tickLower, position.tickUpper, -_toInt128(p.liquidity), auction.tick);
        auction.liquidity = _addLiquidityDeltaIfInRange(
            auction.liquidity,
            auction.tick,
            position.tickLower,
            position.tickUpper,
            -_toInt128(p.liquidity)
        );

        bytes32 positionKey = _positionKey(sourcePositionId);
        LibClAuctionStorage.EncumbranceLock storage lockState = cs.encumbranceLocks[p.clPositionId];

        uint256 unlockA;
        uint256 unlockB;
        if (p.liquidity == liquidityBefore) {
            unlockA = lockState.lockedA;
            unlockB = lockState.lockedB;
        } else {
            unlockA = Math.mulDiv(lockState.lockedA, p.liquidity, liquidityBefore);
            unlockB = Math.mulDiv(lockState.lockedB, p.liquidity, liquidityBefore);
        }

        LibClEncumbranceBridge.unlock(positionKey, auction.poolIdA, unlockA, auction.poolIdB, unlockB, p.clPositionId);

        emit ClLiquidityDecreased(p.clPositionId, p.liquidity, position.liquidity, amountA, amountB);
    }

    function collectClFees(LibClAuctionStorage.CollectClFeesParams calldata p)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        LibCurrency.assertZeroMsgValue();

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClPosition storage position = cs.positions[p.clPositionId];
        uint256 sourcePositionId = position.sourcePositionId;
        if (sourcePositionId == 0) revert ClAuction_Unauthorized(msg.sender, p.clPositionId);

        _requireAuthorized(sourcePositionId);

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[position.auctionId];
        if (auction.cancelled) revert ClAuction_NotActive(position.auctionId);

        LibClPosition.updatePosition(p.clPositionId, 0);

        amountA = position.tokensOwed0;
        amountB = position.tokensOwed1;

        if (amountA > p.amount0Max) amountA = p.amount0Max;
        if (amountB > p.amount1Max) amountB = p.amount1Max;

        if (amountA > 0) {
            position.tokensOwed0 -= uint128(amountA);
            _creditYieldToSourcePosition(auction.poolIdA, _positionKey(sourcePositionId), amountA);
        }
        if (amountB > 0) {
            position.tokensOwed1 -= uint128(amountB);
            _creditYieldToSourcePosition(auction.poolIdB, _positionKey(sourcePositionId), amountB);
        }

        emit ClFeesCollected(p.clPositionId, amountA, amountB);
    }

    function burnClPosition(uint256 clPositionId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClPosition storage position = cs.positions[clPositionId];
        uint256 sourcePositionId = position.sourcePositionId;
        if (sourcePositionId == 0) revert ClAuction_Unauthorized(msg.sender, clPositionId);

        _requireAuthorized(sourcePositionId);

        if (position.liquidity != 0 || position.tokensOwed0 != 0 || position.tokensOwed1 != 0) {
            revert ClAuction_PositionNotClear(clPositionId);
        }

        LibClAuctionStorage.EncumbranceLock storage lockState = cs.encumbranceLocks[clPositionId];
        if (lockState.lockedA != 0 || lockState.lockedB != 0) {
            revert ClAuction_PositionNotClear(clPositionId);
        }

        ClPositionManager(cs.clPositionManager).burn(clPositionId);
        delete cs.positions[clPositionId];
        delete cs.encumbranceLocks[clPositionId];

        emit ClPositionBurned(clPositionId);
    }

    // --- Swap ---

    function swapExactIn(uint256 auctionId, address tokenIn, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ClAuction_InvalidAmount(amountIn);

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[auctionId];
        _requireActivePhase(auction);
        if (cs.swapPaused) revert ClAuction_Paused();

        bool zeroForOne;
        if (tokenIn == auction.tokenA) {
            zeroForOne = true;
        } else if (tokenIn == auction.tokenB) {
            zeroForOne = false;
        } else {
            revert ClAuction_InvalidToken(tokenIn);
        }

        if (LibCurrency.isNative(tokenIn)) {
            LibCurrency.assertMsgValue(tokenIn, amountIn);
        } else {
            LibCurrency.assertZeroMsgValue();
        }

        uint256 balanceBefore = LibCurrency.balanceOfSelf(tokenIn);
        LibCurrency.pull(tokenIn, msg.sender, amountIn);
        uint256 balanceAfter = LibCurrency.balanceOfSelf(tokenIn);
        uint256 actualIn = balanceAfter - balanceBefore;
        if (actualIn != amountIn) revert ClAuction_InputAmountMismatch(amountIn, actualIn);

        uint128 protocolFeeBefore = zeroForOne ? auction.protocolFees0 : auction.protocolFees1;
        int24 tickBefore = auction.tick;

        uint160 sqrtPriceLimitX96 = zeroForOne ? LibClMath.MIN_SQRT_RATIO : LibClMath.MAX_SQRT_RATIO;
        (int256 amount0Delta, int256 amount1Delta) = LibClSwap.executeSwap(
            auctionId,
            zeroForOne,
            int256(actualIn),
            sqrtPriceLimitX96
        );

        uint256 amountInUsed = zeroForOne ? _positiveToUint(amount0Delta) : _positiveToUint(amount1Delta);
        amountOut = zeroForOne ? _negativeToUint(amount1Delta) : _negativeToUint(amount0Delta);

        if (amountInUsed < actualIn) {
            LibCurrency.transfer(tokenIn, msg.sender, actualIn - amountInUsed);
        }

        if (amountOut < amountOutMin) revert ClAuction_Slippage(amountOut, amountOutMin);

        uint128 protocolFeeAfter = zeroForOne ? auction.protocolFees0 : auction.protocolFees1;
        uint256 protocolFeeDelta = uint256(protocolFeeAfter - protocolFeeBefore);

        if (protocolFeeDelta > 0) {
            uint256 feePoolId = zeroForOne ? auction.poolIdA : auction.poolIdB;
            (uint256 toTreasury, uint256 toActive, uint256 toIndex) =
                LibFeeRouter.routeManagedShare(feePoolId, protocolFeeDelta, CL_FEE_SOURCE, false, protocolFeeDelta);

            uint256 backed = toActive + toIndex;
            if (backed > 0) {
                Types.PoolData storage feePool = LibAppStorage.s().pools[feePoolId];
                feePool.trackedBalance += backed;
                if (LibCurrency.isNative(feePool.underlying)) {
                    LibAppStorage.s().nativeTrackedTotal += backed;
                }
            }

            toTreasury;
            if (zeroForOne) {
                auction.protocolFees0 = protocolFeeBefore;
            } else {
                auction.protocolFees1 = protocolFeeBefore;
            }
        }

        address tokenOut = zeroForOne ? auction.tokenB : auction.tokenA;
        LibCurrency.transfer(tokenOut, recipient, amountOut);

        if (tickBefore != auction.tick) {
            emit ClTickCrossed(auctionId, tickBefore, auction.tick);
        }
        emit ClSwap(auctionId, msg.sender, tokenIn, actualIn, amountOut, recipient);
    }

    // --- Helpers ---

    function _requireAuthorized(uint256 positionId) internal view {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        address owner = nft.ownerOf(positionId);

        if (msg.sender == owner) return;
        if (nft.getApproved(positionId) == msg.sender) return;
        if (nft.isApprovedForAll(owner, msg.sender)) return;

        address tba = _computeTBAAddress(positionId);
        if (tba != address(0) && msg.sender == tba) return;

        revert ClAuction_Unauthorized(msg.sender, positionId);
    }

    function _requireActivePhase(LibClAuctionStorage.ClCommunityAuction storage auction) internal view {
        if (!auction.initialized || auction.cancelled || auction.finalized) {
            revert ClAuction_NotActive(auction.auctionId);
        }
        if (block.timestamp < auction.startTime || block.timestamp >= auction.endTime) {
            revert ClAuction_NotActive(auction.auctionId);
        }
    }

    function _ensureTBADeployed(uint256 positionId) internal returns (address tba) {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();

        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = LibPositionNFT.s().positionNFTContract;

        if (registry == address(0) || implementation == address(0) || positionNFT == address(0)) {
            revert ClAuction_TBADeploymentFailed(address(0), address(0));
        }

        tba = IERC6551Registry(registry).account(implementation, ds.tbaSalt, block.chainid, positionNFT, positionId);

        if (tba.code.length > 0) {
            ds.tbaDeployed[positionId] = true;
            ds.tbaConfigLocked = true;
            return tba;
        }

        address deployed = IERC6551Registry(registry).createAccount(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionId
        );

        if (deployed != tba || deployed.code.length == 0) {
            revert ClAuction_TBADeploymentFailed(tba, deployed);
        }

        ds.tbaDeployed[positionId] = true;
        ds.tbaConfigLocked = true;
    }

    function _computeTBAAddress(uint256 positionId) internal view returns (address) {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = LibPositionNFT.s().positionNFTContract;

        if (registry == address(0) || implementation == address(0) || positionNFT == address(0)) {
            return address(0);
        }

        return IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionId
        );
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32) {
        return LibPositionNFT.getPositionKey(address(LibDirectHelpers._positionNFT()), positionId);
    }

    function _validateTicks(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) revert ClAuction_InvalidTickRange(tickLower, tickUpper);
        if (tickSpacing <= 0) revert ClAuction_InvalidTickSpacing(uint24(uint256(int256(tickSpacing))));
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert ClAuction_InvalidTickRange(tickLower, tickUpper);
        }
    }

    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = LibClMath.getAmount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
            amount1 = 0;
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            amount0 = LibClMath.getAmount0ForLiquidity(sqrtPriceX96, sqrtUpperX96, liquidity);
            amount1 = LibClMath.getAmount1ForLiquidity(sqrtLowerX96, sqrtPriceX96, liquidity);
        } else {
            amount0 = 0;
            amount1 = LibClMath.getAmount1ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        }
    }

    function _checkAvailablePrincipal(bytes32 positionKey, uint256 poolId, uint256 required) internal {
        if (required == 0) return;

        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 used = LibEncumbrance.total(positionKey, poolId);
        uint256 available = principal > used ? principal - used : 0;

        if (required > available) {
            revert ClAuction_InsufficientPrincipal(required, available);
        }
    }

    function _updateTicksAndBitmap(
        uint256 auctionId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tickCurrent
    ) internal {
        bool flippedLower = _updateTick(auctionId, tickLower, tickCurrent, liquidityDelta, false);
        bool flippedUpper = _updateTick(auctionId, tickUpper, tickCurrent, liquidityDelta, true);

        LibClAuctionStorage.ClCommunityAuction storage auction = LibClAuctionStorage.s().auctions[auctionId];
        int24 tickSpacing = int24(uint24(auction.tickSpacing));

        if (flippedLower) {
            LibClTickBitmap.flipTick(auctionId, tickLower, tickSpacing);
        }
        if (flippedUpper) {
            LibClTickBitmap.flipTick(auctionId, tickUpper, tickSpacing);
        }
    }

    function _updateTick(uint256 auctionId, int24 tick, int24 tickCurrent, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped)
    {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[auctionId];
        LibClAuctionStorage.TickInfo storage info = cs.ticks[auctionId][tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = _addLiquidityDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = auction.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = auction.feeGrowthGlobal1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        if (upper) {
            info.liquidityNet -= liquidityDelta;
        } else {
            info.liquidityNet += liquidityDelta;
        }

        if (liquidityGrossAfter == 0) {
            info.initialized = false;
        }
    }

    function _addLiquidityDeltaIfInRange(
        uint128 currentLiquidity,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal pure returns (uint128) {
        if (currentTick < tickLower || currentTick >= tickUpper) {
            return currentLiquidity;
        }
        return _addLiquidityDelta(currentLiquidity, liquidityDelta);
    }

    function _addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) internal pure returns (uint128) {
        if (liquidityDelta < 0) {
            uint128 deltaAbs = uint128(uint128(-liquidityDelta));
            if (deltaAbs > liquidity) {
                revert ClAuction_LiquidityUnderflow(deltaAbs, liquidity);
            }
            unchecked {
                return liquidity - deltaAbs;
            }
        }

        return liquidity + uint128(uint128(liquidityDelta));
    }

    function _creditYieldToSourcePosition(uint256 poolId, bytes32 positionKey, uint256 amount) internal {
        if (amount == 0) return;

        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        pool.userAccruedYield[positionKey] += amount;
        pool.yieldReserve += amount;
        pool.trackedBalance += amount;

        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal += amount;
        }
    }

    function _toInt128(uint128 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) {
            revert ClAuction_InvalidAmount(value);
        }
        return int128(uint128(value));
    }

    function _positiveToUint(int256 value) internal pure returns (uint256) {
        if (value < 0) revert ClAuction_InvalidAmount(uint256(-value));
        return uint256(value);
    }

    function _negativeToUint(int256 value) internal pure returns (uint256) {
        if (value > 0) revert ClAuction_InvalidAmount(uint256(value));
        return uint256(-value);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../libraries/LibActiveCreditIndex.sol";
import {LibModuleEncumbrance} from "../../libraries/LibModuleEncumbrance.sol";
import {LibSolvencyChecks} from "../../libraries/LibSolvencyChecks.sol";
import {ReentrancyGuardModifiers} from "../../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal, InsufficientUnencumberedPrincipal} from "../../libraries/Errors.sol";
import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../libraries/LibIlmIsolatedStorage.sol";
import {LibIlmSharesMath} from "../libraries/LibIlmSharesMath.sol";
import {LibIlmInterestMath} from "../libraries/LibIlmInterestMath.sol";
import {LibIlmLiquidationMath} from "../libraries/LibIlmLiquidationMath.sol";
import {IIlmIsolatedOracleAdapter} from "../interfaces/IIlmIsolatedOracleAdapter.sol";
import {
    IlmIsolatedMarketNotCreated,
    IlmIsolatedInvalidInput,
    IlmIsolatedUnauthorized,
    IlmIsolatedHealthyPosition,
    IlmIsolatedOracleStale
} from "../errors/IlmIsolatedErrors.sol";

/// @notice Liquidation facet for ILM isolated profile.
contract ILMIsolatedLiquidationFacet is ReentrancyGuardModifiers {
    event IlmIsolatedAccrueInterest(bytes32 indexed marketId, uint256 interest, uint256 feeShares);
    event IlmIsolatedLiquidate(
        bytes32 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets,
        uint256 badDebtAssets,
        uint256 badDebtShares
    );

    function isolatedLiquidate(
        bytes32 marketId,
        uint256 borrowerPositionId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 liquidatorPositionId
    ) external nonReentrant returns (uint256 seizedOut, uint256 repaidAssetsOut) {
        _requireExactlyOneInput(seizedAssets, repaidShares);

        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }

        _accrueInterest(marketId, market, _ds);

        IlmIsolatedTypes.IlmIsolatedMarketParams storage params = _ds.marketParams[marketId];
        uint256 oraclePrice = _getFreshPrice(params.oracle, _ds.maxStaleness);

        bytes32 borrowerKey = _positionKey(borrowerPositionId);
        bytes32 liquidatorKey = _checkAuthorized(liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedPosition storage borrowerPosition = _ds.position[marketId][borrowerKey];
        bool healthy = LibIlmLiquidationMath.isHealthy(
            borrowerPosition.collateralAssets,
            borrowerPosition.borrowShares,
            market.totalBorrowAssets,
            market.totalBorrowShares,
            oraclePrice,
            params.lltv
        );
        if (healthy) {
            revert IlmIsolatedHealthyPosition();
        }

        uint256 lif = LibIlmLiquidationMath.computeLIF(params.lltv);
        if (seizedAssets > 0) {
            uint256 seizedAssetsQuoted =
                Math.mulDiv(seizedAssets, oraclePrice, IlmIsolatedTypes.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
            uint256 repaidAssetsForInput = _divUp(seizedAssetsQuoted, lif);
            repaidShares =
                LibIlmSharesMath.toSharesUp(repaidAssetsForInput, market.totalBorrowAssets, market.totalBorrowShares);
        } else {
            uint256 repaidAssetsForInput =
                LibIlmSharesMath.toAssetsDown(repaidShares, market.totalBorrowAssets, market.totalBorrowShares);
            uint256 seizedValueInLoanAssets = repaidAssetsForInput * lif;
            seizedAssets =
                Math.mulDiv(seizedValueInLoanAssets, IlmIsolatedTypes.ORACLE_PRICE_SCALE, oraclePrice);
        }

        repaidAssetsOut = LibIlmSharesMath.toAssetsUp(repaidShares, market.totalBorrowAssets, market.totalBorrowShares);
        seizedOut = seizedAssets;

        borrowerPosition.borrowShares -= uint128(repaidShares);
        market.totalBorrowShares -= uint128(repaidShares);
        market.totalBorrowAssets = uint128(_zeroFloorSub(market.totalBorrowAssets, repaidAssetsOut));

        borrowerPosition.collateralAssets -= uint128(seizedAssets);

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (borrowerPosition.collateralAssets == 0 && borrowerPosition.borrowShares > 0) {
            badDebtShares = borrowerPosition.borrowShares;
            badDebtAssets = _min(
                market.totalBorrowAssets,
                LibIlmSharesMath.toAssetsUp(badDebtShares, market.totalBorrowAssets, market.totalBorrowShares)
            );

            market.totalBorrowAssets -= uint128(badDebtAssets);
            market.totalSupplyAssets -= uint128(badDebtAssets);
            market.totalBorrowShares -= uint128(badDebtShares);
            borrowerPosition.borrowShares = 0;
        }

        _debitPrincipal(params.loanPoolId, liquidatorKey, repaidAssetsOut);
        _debitPrincipalIgnoringEncumbrance(params.collateralPoolId, borrowerKey, seizedAssets);
        _creditPrincipal(params.collateralPoolId, liquidatorKey, seizedAssets);
        LibModuleEncumbrance.unencumber(borrowerKey, params.collateralPoolId, _ds.marketModuleId[marketId], seizedAssets);

        emit IlmIsolatedLiquidate(
            marketId, borrowerKey, liquidatorKey, repaidAssetsOut, repaidShares, seizedAssets, badDebtAssets, badDebtShares
        );
    }

    function _accrueInterest(
        bytes32 marketId,
        IlmIsolatedTypes.IlmIsolatedMarket storage market,
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds
    ) internal {
        (uint256 interest, uint256 feeShares) = LibIlmInterestMath.accrueInterest(
            market, _ds.marketParams[marketId], _ds.feeRecipientPositionKey, market.fee, _ds.position[marketId]
        );
        emit IlmIsolatedAccrueInterest(marketId, interest, feeShares);
    }

    function _requireExactlyOneInput(uint256 a, uint256 b) internal pure {
        if ((a == 0 && b == 0) || (a > 0 && b > 0)) {
            revert IlmIsolatedInvalidInput();
        }
    }

    function _checkAuthorized(uint256 positionId) internal view returns (bytes32 positionKey) {
        PositionNFT nft = _positionNft();
        positionKey = nft.getPositionKey(positionId);
        address owner = nft.ownerOf(positionId);
        if (msg.sender == owner || ds().isAuthorizedOperator[positionKey][msg.sender]) {
            return positionKey;
        }
        revert IlmIsolatedUnauthorized();
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32) {
        return _positionNft().getPositionKey(positionId);
    }

    function _positionNft() internal view returns (PositionNFT nft) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmIsolatedUnauthorized();
        }
        nft = PositionNFT(ns.positionNFTContract);
    }

    function _getFreshPrice(address oracle, uint256 maxStaleness) internal view returns (uint256 price) {
        if (maxStaleness == 0) {
            revert IlmIsolatedInvalidInput();
        }

        uint256 updatedAt;
        (price, updatedAt) = IIlmIsolatedOracleAdapter(oracle).getIsolatedPrice(oracle);
        if (price == 0) {
            revert IlmIsolatedInvalidInput();
        }
        if (updatedAt + maxStaleness < block.timestamp) {
            revert IlmIsolatedOracleStale(updatedAt, maxStaleness);
        }
    }

    function _creditPrincipal(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.pools[poolId].userPrincipal[positionKey] += assets;
        app.pools[poolId].totalDeposits += assets;
    }

    function _debitPrincipal(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 available = LibSolvencyChecks.calculateAvailablePrincipal(app.pools[poolId], positionKey, poolId);
        if (assets > available) {
            revert InsufficientUnencumberedPrincipal(assets, available);
        }
        app.pools[poolId].userPrincipal[positionKey] -= assets;
        app.pools[poolId].totalDeposits -= assets;
    }

    function _debitPrincipalIgnoringEncumbrance(uint256 poolId, bytes32 positionKey, uint256 assets) internal {
        if (assets == 0) {
            return;
        }
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 principal = app.pools[poolId].userPrincipal[positionKey];
        if (assets > principal) {
            revert InsufficientPrincipal(assets, principal);
        }
        app.pools[poolId].userPrincipal[positionKey] = principal - assets;
        app.pools[poolId].totalDeposits -= assets;
    }

    function _zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return y >= x ? 0 : x - y;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function ds() internal pure returns (LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage) {
        return LibIlmIsolatedStorage.s();
    }
}

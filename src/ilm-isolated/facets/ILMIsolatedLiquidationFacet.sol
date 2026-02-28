// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../libraries/LibActiveCreditIndex.sol";
import {LibFeeRouter} from "../../libraries/LibFeeRouter.sol";
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
    bytes32 internal constant ILM_INTEREST_FEE_SOURCE = keccak256("ILM_INTEREST_FEE");
    bytes32 internal constant ILM_LIQUIDATION_FEE_SOURCE = keccak256("ILM_LIQUIDATION_FEE");
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    event IlmIsolatedAccrueInterest(bytes32 indexed marketId, uint256 interest, uint256 protocolFeeAccrued);
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
    event IlmIsolatedLiquidationRevenue(
        bytes32 indexed marketId,
        bytes32 indexed borrowerKey,
        bytes32 indexed liquidatorKey,
        uint256 grossSeizedAssets,
        uint256 protocolFeeAssets,
        uint256 netSeizedAssets
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
        uint256 grossSeizedAssets = seizedAssets;
        uint256 protocolFeeCollateral =
            (grossSeizedAssets * _ds.marketLiquidationFeeBps[marketId]) / BPS_DENOMINATOR;
        uint256 netSeizedAssets = grossSeizedAssets - protocolFeeCollateral;
        seizedOut = netSeizedAssets;

        uint256 borrowAssetsBeforeRepay = market.totalBorrowAssets;
        borrowerPosition.borrowShares -= uint128(repaidShares);
        market.totalBorrowShares -= uint128(repaidShares);
        market.totalBorrowAssets = uint128(_zeroFloorSub(market.totalBorrowAssets, repaidAssetsOut));

        borrowerPosition.collateralAssets -= uint128(grossSeizedAssets);

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (borrowerPosition.collateralAssets == 0 && borrowerPosition.borrowShares > 0) {
            uint256 borrowAssetsBeforeWriteDown = market.totalBorrowAssets;
            badDebtShares = borrowerPosition.borrowShares;
            badDebtAssets = _min(
                market.totalBorrowAssets,
                LibIlmSharesMath.toAssetsUp(badDebtShares, market.totalBorrowAssets, market.totalBorrowShares)
            );

            market.totalBorrowAssets -= uint128(badDebtAssets);
            market.totalSupplyAssets -= uint128(badDebtAssets);
            market.totalBorrowShares -= uint128(badDebtShares);
            borrowerPosition.borrowShares = 0;

            _writeDownProtocolFeeClaim(marketId, badDebtAssets, borrowAssetsBeforeWriteDown, _ds);
        }

        _realizeProtocolInterestFee(marketId, params.loanPoolId, repaidAssetsOut, borrowAssetsBeforeRepay, _ds);
        _debitPrincipal(params.loanPoolId, liquidatorKey, repaidAssetsOut);
        _debitPrincipalIgnoringEncumbrance(params.collateralPoolId, borrowerKey, grossSeizedAssets);
        _creditPrincipal(params.collateralPoolId, liquidatorKey, netSeizedAssets);
        if (protocolFeeCollateral > 0) {
            LibFeeRouter.routeManagedShare(
                params.collateralPoolId, protocolFeeCollateral, ILM_LIQUIDATION_FEE_SOURCE, false, 0
            );
        }
        LibModuleEncumbrance.unencumber(
            borrowerKey, params.collateralPoolId, _ds.marketModuleId[marketId], grossSeizedAssets
        );

        if (market.totalBorrowAssets == 0) {
            _ds.marketProtocolFeeAssets[marketId] = 0;
        }

        emit IlmIsolatedLiquidate(
            marketId, borrowerKey, liquidatorKey, repaidAssetsOut, repaidShares, netSeizedAssets, badDebtAssets, badDebtShares
        );
        emit IlmIsolatedLiquidationRevenue(
            marketId, borrowerKey, liquidatorKey, grossSeizedAssets, protocolFeeCollateral, netSeizedAssets
        );
    }

    function _accrueInterest(
        bytes32 marketId,
        IlmIsolatedTypes.IlmIsolatedMarket storage market,
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds
    ) internal {
        (uint256 interest, uint256 protocolFeeAccrued) =
            LibIlmInterestMath.accrueInterest(market, _ds.marketParams[marketId], market.fee);
        _ds.marketProtocolFeeAssets[marketId] += protocolFeeAccrued;
        emit IlmIsolatedAccrueInterest(marketId, interest, protocolFeeAccrued);
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

    function _realizeProtocolInterestFee(
        bytes32 marketId,
        uint256 loanPoolId,
        uint256 debtReductionAssets,
        uint256 borrowAssetsBefore,
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds
    ) internal {
        if (debtReductionAssets == 0 || borrowAssetsBefore == 0) {
            return;
        }

        uint256 claim = _ds.marketProtocolFeeAssets[marketId];
        if (claim == 0) {
            return;
        }

        uint256 realized = claim * debtReductionAssets / borrowAssetsBefore;
        if (realized > claim) {
            realized = claim;
        }
        if (realized > 0) {
            _ds.marketProtocolFeeAssets[marketId] = claim - realized;
            LibFeeRouter.routeManagedShare(loanPoolId, realized, ILM_INTEREST_FEE_SOURCE, false, 0);
        }
    }

    function _writeDownProtocolFeeClaim(
        bytes32 marketId,
        uint256 writeDownAssets,
        uint256 borrowAssetsBeforeWriteDown,
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds
    ) internal {
        if (writeDownAssets == 0 || borrowAssetsBeforeWriteDown == 0) {
            return;
        }

        uint256 claim = _ds.marketProtocolFeeAssets[marketId];
        if (claim == 0) {
            return;
        }

        uint256 writeDown = claim * writeDownAssets / borrowAssetsBeforeWriteDown;
        if (writeDown > claim) {
            writeDown = claim;
        }
        _ds.marketProtocolFeeAssets[marketId] = claim - writeDown;
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibModuleEncumbrance} from "../../libraries/LibModuleEncumbrance.sol";
import {LibSolvencyChecks} from "../../libraries/LibSolvencyChecks.sol";
import {ReentrancyGuardModifiers} from "../../libraries/LibReentrancyGuard.sol";
import {InsufficientUnencumberedPrincipal} from "../../libraries/Errors.sol";
import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../libraries/LibIlmIsolatedStorage.sol";
import {LibIlmSharesMath} from "../libraries/LibIlmSharesMath.sol";
import {LibIlmInterestMath} from "../libraries/LibIlmInterestMath.sol";
import {
    IlmIsolatedMarketNotCreated,
    IlmIsolatedInvalidInput,
    IlmIsolatedUnauthorized,
    IlmIsolatedInsufficientLiquidity
} from "../errors/IlmIsolatedErrors.sol";

/// @notice Supply/withdraw core facet for ILM isolated profile.
contract ILMIsolatedFacet is ReentrancyGuardModifiers {
    event IlmIsolatedAccrueInterest(bytes32 indexed marketId, uint256 interest, uint256 feeShares);
    event IlmIsolatedSupply(bytes32 indexed marketId, bytes32 indexed positionKey, uint256 assets, uint256 shares);
    event IlmIsolatedWithdraw(bytes32 indexed marketId, bytes32 indexed positionKey, uint256 assets, uint256 shares);

    function isolatedSupply(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        nonReentrant
        returns (uint256 assetsOut, uint256 sharesOut)
    {
        _requireExactlyOneInput(assets, shares);

        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }

        bytes32 positionKey = _checkAuthorized(positionId);
        _accrueInterest(marketId, market, _ds);

        if (assets > 0) {
            assetsOut = assets;
            sharesOut = LibIlmSharesMath.toSharesDown(assetsOut, market.totalSupplyAssets, market.totalSupplyShares);
        } else {
            sharesOut = shares;
            assetsOut = LibIlmSharesMath.toAssetsUp(sharesOut, market.totalSupplyAssets, market.totalSupplyShares);
        }

        IlmIsolatedTypes.IlmIsolatedMarketParams storage params = _ds.marketParams[marketId];
        uint256 moduleId = _ds.marketModuleId[marketId];
        _enforceAvailablePrincipal(positionKey, params.loanPoolId, assetsOut);
        LibModuleEncumbrance.encumber(positionKey, params.loanPoolId, moduleId, assetsOut);

        IlmIsolatedTypes.IlmIsolatedPosition storage position = _ds.position[marketId][positionKey];
        position.supplyShares += sharesOut;

        uint256 newTotalSupplyAssets = uint256(market.totalSupplyAssets) + assetsOut;
        uint256 newTotalSupplyShares = uint256(market.totalSupplyShares) + sharesOut;
        if (newTotalSupplyAssets > type(uint128).max || newTotalSupplyShares > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }
        market.totalSupplyAssets = uint128(newTotalSupplyAssets);
        market.totalSupplyShares = uint128(newTotalSupplyShares);

        emit IlmIsolatedSupply(marketId, positionKey, assetsOut, sharesOut);
    }

    function isolatedWithdraw(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        nonReentrant
        returns (uint256 assetsOut, uint256 sharesOut)
    {
        _requireExactlyOneInput(assets, shares);

        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }

        bytes32 positionKey = _checkAuthorized(positionId);
        _accrueInterest(marketId, market, _ds);

        if (assets > 0) {
            assetsOut = assets;
            sharesOut = LibIlmSharesMath.toSharesUp(assetsOut, market.totalSupplyAssets, market.totalSupplyShares);
        } else {
            sharesOut = shares;
            assetsOut = LibIlmSharesMath.toAssetsDown(sharesOut, market.totalSupplyAssets, market.totalSupplyShares);
        }

        IlmIsolatedTypes.IlmIsolatedPosition storage position = _ds.position[marketId][positionKey];
        if (sharesOut > position.supplyShares) {
            revert IlmIsolatedInvalidInput();
        }
        if (assetsOut > market.totalSupplyAssets || sharesOut > market.totalSupplyShares) {
            revert IlmIsolatedInvalidInput();
        }

        uint256 newTotalSupplyAssets = uint256(market.totalSupplyAssets) - assetsOut;
        uint256 newTotalSupplyShares = uint256(market.totalSupplyShares) - sharesOut;

        uint256 totalBorrowAssets = market.totalBorrowAssets;
        if (totalBorrowAssets > newTotalSupplyAssets) {
            revert IlmIsolatedInsufficientLiquidity(totalBorrowAssets, newTotalSupplyAssets);
        }

        position.supplyShares -= sharesOut;
        market.totalSupplyAssets = uint128(newTotalSupplyAssets);
        market.totalSupplyShares = uint128(newTotalSupplyShares);

        IlmIsolatedTypes.IlmIsolatedMarketParams storage params = _ds.marketParams[marketId];
        uint256 moduleId = _ds.marketModuleId[marketId];
        LibModuleEncumbrance.unencumber(positionKey, params.loanPoolId, moduleId, assetsOut);

        emit IlmIsolatedWithdraw(marketId, positionKey, assetsOut, sharesOut);
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

    function _requireExactlyOneInput(uint256 assets, uint256 shares) internal pure {
        if ((assets == 0 && shares == 0) || (assets > 0 && shares > 0)) {
            revert IlmIsolatedInvalidInput();
        }
    }

    function _checkAuthorized(uint256 positionId) internal view returns (bytes32 positionKey) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmIsolatedUnauthorized();
        }

        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        positionKey = nft.getPositionKey(positionId);
        address owner = nft.ownerOf(positionId);
        if (msg.sender == owner || ds().isAuthorizedOperator[positionKey][msg.sender]) {
            return positionKey;
        }
        revert IlmIsolatedUnauthorized();
    }

    function _enforceAvailablePrincipal(bytes32 positionKey, uint256 poolId, uint256 amount) internal view {
        uint256 available = LibSolvencyChecks.calculateAvailablePrincipal(LibAppStorage.s().pools[poolId], positionKey, poolId);
        if (amount > available) {
            revert InsufficientUnencumberedPrincipal(amount, available);
        }
    }

    function ds() internal pure returns (LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage) {
        return LibIlmIsolatedStorage.s();
    }
}

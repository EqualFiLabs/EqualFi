// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPerpsDomain} from "./LibPerpsDomain.sol";
import {LibPerpsIdentity} from "./LibPerpsIdentity.sol";
import {LibPerpsIntent} from "./LibPerpsIntent.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {
    Perps_AccountNotFound,
    Perps_DecreasePaused,
    Perps_InsufficientPerpsLiquidity,
    Perps_MarketNotFound,
    Perps_RiskLimitExceeded
} from "./PerpsErrors.sol";

interface IPerpsExecutionPositionNFT {
    function getPositionKey(uint256 tokenId) external view returns (bytes32);
}

/// @notice Account lifecycle and collateral reservation entry points for perps participants.
contract PerpsExecutionFacet {
    struct AddCollateralParams {
        bytes32 marketId;
        bytes32 accountId;
        address collateralAsset;
        uint256 amount;
    }

    struct RemoveCollateralParams {
        bytes32 marketId;
        bytes32 accountId;
        address collateralAsset;
        uint256 amount;
    }

    event PerpsAccountCreated(bytes32 indexed accountId, bytes32 indexed positionKey, uint256 indexed positionTokenId);
    event PerpsCollateralAdded(bytes32 indexed marketId, bytes32 indexed accountId, address collateralAsset, uint256 amount);
    event PerpsCollateralRemoved(bytes32 indexed marketId, bytes32 indexed accountId, address collateralAsset, uint256 amount);

    function createAccount(uint256 positionId, uint256 subaccountNonce) external returns (bytes32 accountId) {
        LibPerpsIntent.requirePositionAuthority(positionId);

        bytes32 positionKey = _positionNft().getPositionKey(positionId);
        accountId = LibPerpsIdentity.deriveAccountId(positionKey, subaccountNonce);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsAccount storage account = ps.accounts[accountId];
        if (!account.exists) {
            account.accountId = accountId;
            account.positionKey = positionKey;
            account.positionTokenId = positionId;
            account.nonce = ps.minValidNonce[accountId];
            account.exists = true;
            ps.accountCount += 1;
            emit PerpsAccountCreated(accountId, positionKey, positionId);
        }
    }

    function addCollateral(AddCollateralParams calldata p) external {
        if (p.amount == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        if (p.collateralAsset != market.collateralAsset) revert Perps_RiskLimitExceeded();

        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        ps.accountCollateral[p.accountId][p.marketId] += p.amount;
        ps.marketState[p.marketId].reservedCollateral += p.amount;
        LibPerpsDomain.reserveIsolatedBacking(p.amount);

        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);
        emit PerpsCollateralAdded(p.marketId, p.accountId, p.collateralAsset, p.amount);
    }

    function removeCollateral(RemoveCollateralParams calldata p) external {
        if (p.amount == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        if (market.pauseDecrease) revert Perps_DecreasePaused(p.marketId);
        if (p.collateralAsset != market.collateralAsset) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);

        uint256 currentCollateral = ps.accountCollateral[p.accountId][p.marketId];
        if (currentCollateral < p.amount) {
            revert Perps_InsufficientPerpsLiquidity(p.amount, currentCollateral);
        }

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        ps.accountCollateral[p.accountId][p.marketId] = currentCollateral - p.amount;
        ps.marketState[p.marketId].reservedCollateral -= p.amount;
        LibPerpsDomain.releaseIsolatedBacking(p.amount);

        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[p.marketId];
        LibPerpsDomain.enforceDomainSolvency(state.insuranceBalance, state.badDebt);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);

        emit PerpsCollateralRemoved(p.marketId, p.accountId, p.collateralAsset, p.amount);
    }

    function deriveAccountIdForPosition(uint256 positionId, uint256 subaccountNonce) external view returns (bytes32) {
        bytes32 positionKey = _positionNft().getPositionKey(positionId);
        return LibPerpsIdentity.deriveAccountId(positionKey, subaccountNonce);
    }

    function accountExists(bytes32 accountId) external view returns (bool) {
        return LibPerpsStorage.s().accounts[accountId].exists;
    }

    function getAccount(bytes32 accountId) external view returns (LibPerpsStorage.PerpsAccount memory) {
        return _requireAccount(accountId);
    }

    function getAccountCollateral(bytes32 marketId, bytes32 accountId) external view returns (uint256) {
        _requireMarket(marketId);
        _requireAccount(accountId);
        return LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function _singlePoolArray(uint256 poolId) private pure returns (uint256[] memory poolIds) {
        poolIds = new uint256[](1);
        poolIds[0] = poolId;
    }

    function _positionNft() internal view returns (IPerpsExecutionPositionNFT nft) {
        address nftAddress = LibPositionNFT.s().positionNFTContract;
        if (nftAddress == address(0)) revert Perps_RiskLimitExceeded();
        return IPerpsExecutionPositionNFT(nftAddress);
    }

    function _requireAccount(bytes32 accountId) internal view returns (LibPerpsStorage.PerpsAccount storage account) {
        account = LibPerpsStorage.s().accounts[accountId];
        if (!account.exists) revert Perps_AccountNotFound(accountId);
    }

    function _requireMarket(bytes32 marketId) internal view returns (LibPerpsStorage.PerpsMarket storage market) {
        market = LibPerpsStorage.s().markets[marketId];
        if (!market.exists) revert Perps_MarketNotFound(marketId);
    }
}

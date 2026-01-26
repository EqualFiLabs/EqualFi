// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "./LibPositionNFT.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {Types} from "./Types.sol";
import {PoolNotInitialized, NotNFTOwner} from "./Errors.sol";
import {DirectTypes} from "./DirectTypes.sol";
import {
    DirectError_InvalidConfiguration,
    DirectError_InvalidPositionNFT,
    DirectError_InvalidRatio,
    DirectError_InvalidTimestamp,
    DirectError_ZeroAmount
} from "./Errors.sol";

/// @notice Shared internal helpers for EqualLend direct facets
library LibDirectHelpers {
    using SafeERC20 for IERC20;

    /// @notice Require msg.sender to own the PositionNFT
    function _requireNFTOwnership(PositionNFT nft, uint256 tokenId) internal view {
        if (nft.ownerOf(tokenId) != msg.sender) {
            revert NotNFTOwner(msg.sender, tokenId);
        }
    }

    /// @notice Require msg.sender to be owner or approved for the PositionNFT
    function _requireBorrowerAuthority(PositionNFT nft, uint256 tokenId) internal view {
        address owner = nft.ownerOf(tokenId);
        if (
            msg.sender != owner &&
            nft.getApproved(tokenId) != msg.sender &&
            !nft.isApprovedForAll(owner, msg.sender)
        ) {
            revert NotNFTOwner(msg.sender, tokenId);
        }
    }

    /// @notice Validate borrower-posted offer parameters and referenced pools
    function _validateBorrowerOfferParams(DirectTypes.DirectBorrowerOfferParams calldata params) internal view {
        _validateOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowLenderCall);
        if (params.durationSeconds == 0) revert DirectError_InvalidTimestamp();
        if (params.principal == 0 || params.collateralLockAmount == 0) revert DirectError_ZeroAmount();
        _pool(params.lenderPoolId);
        _pool(params.collateralPoolId);
    }

    /// @notice Validate lender-posted offer parameters and referenced pools
    function _validateOfferParams(DirectTypes.DirectOfferParams calldata params) internal view {
        _validateOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowLenderCall);
        if (params.durationSeconds == 0) revert DirectError_InvalidTimestamp();
        if (params.principal == 0 || params.collateralLockAmount == 0) revert DirectError_ZeroAmount();
        _pool(params.lenderPoolId);
        _pool(params.collateralPoolId);
    }

    /// @notice Validate ratio tranche offer parameters and referenced pools
    function _validateRatioTrancheParams(DirectTypes.DirectRatioTrancheParams calldata params) internal view {
        _validateOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowLenderCall);
        if (params.durationSeconds == 0) revert DirectError_InvalidTimestamp();
        if (params.principalCap == 0 || params.priceNumerator == 0 || params.priceDenominator == 0) {
            revert DirectError_InvalidRatio();
        }
        if (params.minPrincipalPerFill == 0 || params.minPrincipalPerFill > params.principalCap) {
            revert DirectError_InvalidRatio();
        }
        uint256 minCollateral =
            Math.mulDiv(params.minPrincipalPerFill, params.priceNumerator, params.priceDenominator);
        if (minCollateral == 0) revert DirectError_InvalidRatio();
        _pool(params.lenderPoolId);
        _pool(params.collateralPoolId);
    }

    /// @notice Validate borrower ratio tranche offer parameters and referenced pools
    function _validateBorrowerRatioTrancheParams(DirectTypes.DirectBorrowerRatioTrancheParams calldata params) internal view {
        _validateOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowLenderCall);
        if (params.durationSeconds == 0) revert DirectError_InvalidTimestamp();
        if (params.collateralCap == 0 || params.priceNumerator == 0 || params.priceDenominator == 0) {
            revert DirectError_InvalidRatio();
        }
        if (params.minCollateralPerFill == 0 || params.minCollateralPerFill > params.collateralCap) {
            revert DirectError_InvalidRatio();
        }
        // Ensure minimum fill produces non-zero principal
        uint256 minPrincipal =
            Math.mulDiv(params.minCollateralPerFill, params.priceNumerator, params.priceDenominator);
        if (minPrincipal == 0) revert DirectError_InvalidRatio();
        _pool(params.lenderPoolId);
        _pool(params.collateralPoolId);
    }

    /// @notice Validate offer feature flags (placeholder for future constraints)
    function _validateOfferFlags(bool allowEarlyRepay, bool allowEarlyExercise, bool allowLenderCall) internal pure {
        if (allowEarlyRepay || allowEarlyExercise || allowLenderCall) {}
    }

    /// @notice Annualize simple interest for a given term using APR in basis points
    /// @dev Rounds down; returns 0 if any input is 0
    function _annualizedInterestAmount(uint256 principal, uint256 aprBps, uint256 durationSeconds)
        internal
        pure
        returns (uint256)
    {
        if (aprBps == 0 || durationSeconds == 0 || principal == 0) return 0;
        // interest = principal * aprBps * durationSeconds / (365 days * 10_000)
        uint256 timeScaledRate = aprBps * durationSeconds;
        return Math.mulDiv(principal, timeScaledRate, (365 days) * 10_000);
    }

    /// @notice Validate direct config split and treasury constraints
    function _validateConfig(DirectTypes.DirectConfig calldata config) internal pure {
        if (config.platformFeeBps > 10_000) revert DirectError_InvalidConfiguration();
        if (config.interestLenderBps > 10_000) revert DirectError_InvalidConfiguration();
        if (config.platformFeeLenderBps > 10_000) revert DirectError_InvalidConfiguration();
        if (config.defaultLenderBps > 10_000) revert DirectError_InvalidConfiguration();
    }

    /// @notice Pull tokens and require the exact amount was received (guards fee-on-transfer tokens)
    function _pullExact(address token, uint256 amount) internal {
        _pullExactFrom(msg.sender, token, amount);
    }

    /// @notice Pull tokens from a specified address and require the exact amount was received
    function _pullExactFrom(address from, address token, uint256 amount) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        require(received == amount, "Direct: insufficient amount received");
    }

    /// @notice Return the PositionNFT instance and validate configuration
    function _positionNFT() internal view returns (PositionNFT nft) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        nft = PositionNFT(ns.positionNFTContract);
    }

    /// @notice Return pool data for a valid pool id
    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
        return p;
    }
}

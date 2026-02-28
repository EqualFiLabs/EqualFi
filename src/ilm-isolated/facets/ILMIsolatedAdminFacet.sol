// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {LibIlmInterestMath} from "../libraries/LibIlmInterestMath.sol";
import {LibIlmIsolatedStorage} from "../libraries/LibIlmIsolatedStorage.sol";
import {
    IlmIsolatedMarketNotCreated,
    IlmIsolatedMarketAlreadyCreated,
    IlmIsolatedInvalidInput,
    IlmIsolatedZeroAddress,
    IlmIsolatedUnauthorized,
    IlmIsolatedIrmNotEnabled,
    IlmIsolatedLltvNotEnabled,
    IlmIsolatedFeeTooHigh,
    IlmIsolatedManagedLoanPoolRequired,
    IlmIsolatedManagedMarketCreatorUnauthorized,
    IlmIsolatedInvalidFeeBps
} from "../errors/IlmIsolatedErrors.sol";

/// @notice Admin facet for ILM isolated profile governance and market creation.
contract ILMIsolatedAdminFacet {
    event IlmIsolatedCreateMarket(
        bytes32 indexed marketId, uint256 indexed moduleId, IlmIsolatedTypes.IlmIsolatedMarketParams params
    );
    event IlmIsolatedEnableIrm(address indexed irm);
    event IlmIsolatedEnableLltv(uint256 indexed lltv);
    event IlmIsolatedSetFee(bytes32 indexed marketId, uint256 fee);
    event IlmIsolatedSetFeeRecipientPositionKey(bytes32 indexed positionKey);
    event IlmIsolatedSetMaxStaleness(uint256 maxStaleness);
    event IlmIsolatedSetOwner(address indexed owner);
    event IlmIsolatedSetAuthorization(bytes32 indexed positionKey, address indexed operator, bool authorized);
    event IlmIsolatedSetIrmManagedOnly(address indexed irm, bool managedOnly);
    event IlmIsolatedSetMarketLiquidationFeeBps(bytes32 indexed marketId, uint16 bps);

    function createIlmIsolatedMarket(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params, uint256 moduleId)
        external
        returns (bytes32 marketId)
    {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage state = LibIlmIsolatedStorage.s();
        if (!state.isIrmEnabled[params.irm]) {
            revert IlmIsolatedIrmNotEnabled(params.irm);
        }
        if (params.lltv >= IlmIsolatedTypes.WAD || !state.isLltvEnabled[params.lltv]) {
            revert IlmIsolatedLltvNotEnabled(params.lltv);
        }
        if (state.isIrmManagedOnly[params.irm]) {
            LibAppStorage.AppStorage storage app = LibAppStorage.s();
            if (!app.pools[params.loanPoolId].initialized || !app.pools[params.loanPoolId].isManagedPool) {
                revert IlmIsolatedManagedLoanPoolRequired(params.loanPoolId);
            }
            address manager = app.pools[params.loanPoolId].manager;
            if (msg.sender != manager && msg.sender != state.owner) {
                revert IlmIsolatedManagedMarketCreatorUnauthorized(params.loanPoolId, msg.sender, manager);
            }
        }

        marketId = LibIlmIsolatedStorage.deriveMarketId(params);
        if (state.market[marketId].lastUpdate != 0) {
            revert IlmIsolatedMarketAlreadyCreated(marketId);
        }

        state.marketParams[marketId] = params;
        state.marketModuleId[marketId] = moduleId;

        if (block.timestamp > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }
        state.market[marketId].lastUpdate = uint128(block.timestamp);

        emit IlmIsolatedCreateMarket(marketId, moduleId, params);
    }

    function enableIrm(address irm) external {
        _onlyOwner();
        ds().isIrmEnabled[irm] = true;
        emit IlmIsolatedEnableIrm(irm);
    }

    function setIrmManagedOnly(address irm, bool managedOnly) external {
        _onlyOwner();
        ds().isIrmManagedOnly[irm] = managedOnly;
        emit IlmIsolatedSetIrmManagedOnly(irm, managedOnly);
    }

    function enableLltv(uint256 lltv) external {
        _onlyOwner();
        if (lltv >= IlmIsolatedTypes.WAD) {
            revert IlmIsolatedLltvNotEnabled(lltv);
        }
        ds().isLltvEnabled[lltv] = true;
        emit IlmIsolatedEnableLltv(lltv);
    }

    function setFee(bytes32 marketId, uint256 fee) external {
        _onlyOwner();
        if (fee > IlmIsolatedTypes.MAX_FEE) {
            revert IlmIsolatedFeeTooHigh(fee, IlmIsolatedTypes.MAX_FEE);
        }

        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        IlmIsolatedTypes.IlmIsolatedMarket storage market = _ds.market[marketId];
        if (market.lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }

        (, uint256 protocolFeeAccrued) = LibIlmInterestMath.accrueInterest(market, _ds.marketParams[marketId], market.fee);
        _ds.marketProtocolFeeAssets[marketId] += protocolFeeAccrued;
        market.fee = uint128(fee);

        emit IlmIsolatedSetFee(marketId, fee);
    }

    /// @notice Deprecated for interest fee routing; retained for compatibility.
    function setFeeRecipientPositionKey(bytes32 positionKey) external {
        _onlyOwner();
        ds().feeRecipientPositionKey = positionKey;
        emit IlmIsolatedSetFeeRecipientPositionKey(positionKey);
    }

    function setMarketLiquidationFeeBps(bytes32 marketId, uint16 bps) external {
        _onlyOwner();
        if (bps > 10_000) {
            revert IlmIsolatedInvalidFeeBps(bps);
        }
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage _ds = ds();
        if (_ds.market[marketId].lastUpdate == 0) {
            revert IlmIsolatedMarketNotCreated(marketId);
        }
        _ds.marketLiquidationFeeBps[marketId] = bps;
        emit IlmIsolatedSetMarketLiquidationFeeBps(marketId, bps);
    }

    function setMaxStaleness(uint256 maxStaleness) external {
        _onlyOwner();
        if (maxStaleness == 0) {
            revert IlmIsolatedInvalidInput();
        }
        ds().maxStaleness = maxStaleness;
        emit IlmIsolatedSetMaxStaleness(maxStaleness);
    }

    function setOwner(address newOwner) external {
        _onlyOwner();
        if (newOwner == address(0)) {
            revert IlmIsolatedZeroAddress();
        }
        ds().owner = newOwner;
        emit IlmIsolatedSetOwner(newOwner);
    }

    function setAuthorization(bytes32 positionKey, address operator, bool authorized) external {
        _requirePositionOwner(positionKey);
        ds().isAuthorizedOperator[positionKey][operator] = authorized;
        emit IlmIsolatedSetAuthorization(positionKey, operator, authorized);
    }

    function _onlyOwner() internal view {
        if (msg.sender != ds().owner) {
            revert IlmIsolatedUnauthorized();
        }
    }

    function _requirePositionOwner(bytes32 positionKey) internal view {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmIsolatedUnauthorized();
        }

        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        uint256 balance = nft.balanceOf(msg.sender);
        for (uint256 i = 0; i < balance; ++i) {
            uint256 tokenId = nft.tokenOfOwnerByIndex(msg.sender, i);
            if (nft.getPositionKey(tokenId) == positionKey) {
                return;
            }
        }

        revert IlmIsolatedUnauthorized();
    }

    function ds() internal pure returns (LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage) {
        return LibIlmIsolatedStorage.s();
    }
}

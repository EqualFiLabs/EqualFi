// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import "../libraries/Errors.sol";

/// @notice Shared storage + helpers for EqualIndex V3 facets.
abstract contract EqualIndexBaseV3 {
    struct CreateIndexParams {
        string name;
        string symbol;
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps; // per-asset fee in basis points
        uint16[] burnFeeBps; // per-asset fee in basis points
        uint16 flashFeeBps;
    }

    struct IndexView {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct Index {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct EqualIndexStorage {
        uint256 indexCount;
        mapping(uint256 => Index) indexes;
        mapping(uint256 => mapping(address => uint256)) vaultBalances; // indexId -> asset -> balance
        mapping(uint256 => mapping(address => uint256)) feePots; // indexId -> asset -> accumulated fees
        mapping(uint256 => uint256) indexToPoolId; // indexId -> poolId for index token pool
        uint16 poolFeeShareBps; // share of flash loan fees routed through pool fee router
        uint16 mintBurnFeeIndexShareBps; // share of mint/burn fees routed through pool fee router
    }

    bytes32 internal constant EQUAL_INDEX_V3_STORAGE_POSITION = keccak256("equal.index.storage.v3");

    modifier onlyTimelock() {
        if (msg.sender != LibAppStorage.timelockAddress(LibAppStorage.s())) revert Unauthorized();
        _;
    }

    modifier indexExists(uint256 indexId) {
        if (indexId >= s().indexCount) revert UnknownIndex(indexId);
        _;
    }

    function s() internal pure returns (EqualIndexStorage storage store) {
        bytes32 position = EQUAL_INDEX_V3_STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function _requireIndexActive(Index storage idx, uint256 indexId) internal view {
        if (idx.paused) revert IndexPaused(indexId);
    }

    function _validateFeeCaps(uint16[] calldata mintFeeBps, uint16[] calldata burnFeeBps, uint16 flashFeeBps)
        internal
        pure
    {
        uint256 len = mintFeeBps.length;
        for (uint256 i = 0; i < len; i++) {
            if (mintFeeBps[i] > 1000) revert InvalidParameterRange("mintFeeBps too high");
        }
        len = burnFeeBps.length;
        for (uint256 i = 0; i < len; i++) {
            if (burnFeeBps[i] > 1000) revert InvalidParameterRange("burnFeeBps too high");
        }
        if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");
    }

    function _poolFeeShareBps() internal view returns (uint16) {
        uint16 configured = s().poolFeeShareBps;
        if (configured == 0) {
            return 1000; // default 10% for flash loans
        }
        return configured;
    }

    function _mintBurnFeeIndexShareBps() internal view returns (uint16) {
        uint16 configured = s().mintBurnFeeIndexShareBps;
        if (configured == 0) {
            return 4000; // default 40% for mint/burn
        }
        return configured;
    }

    function _getIndexAssetsPaginated(
        Index storage idx,
        uint256 offset,
        uint256 limit
    )
        internal
        view
        returns (
            address[] memory assets,
            uint256[] memory bundleAmounts,
            uint16[] memory mintFeeBps,
            uint16[] memory burnFeeBps
        )
    {
        uint256 total = idx.assets.length;
        if (offset >= total) {
            return (new address[](0), new uint256[](0), new uint16[](0), new uint16[](0));
        }

        uint256 remaining = total - offset;
        if (limit == 0 || limit > remaining) {
            limit = remaining;
        }

        assets = new address[](limit);
        bundleAmounts = new uint256[](limit);
        mintFeeBps = new uint16[](limit);
        burnFeeBps = new uint16[](limit);

        for (uint256 i = 0; i < limit; i++) {
            uint256 idxOffset = offset + i;
            assets[i] = idx.assets[idxOffset];
            bundleAmounts[i] = idx.bundleAmounts[idxOffset];
            mintFeeBps[i] = idx.mintFeeBps[idxOffset];
            burnFeeBps[i] = idx.burnFeeBps[idxOffset];
        }
    }
}

interface IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256 indexId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "./Types.sol";
import "./Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice EqualIndex storage, events, and errors.
library LibEqualIndex {
    bytes32 internal constant EQUAL_INDEX_STORAGE_POSITION = keccak256("equal.index.storage");
    uint256 internal constant INDEX_SCALE = 1e18;

    struct Index {
        address[] assets;
        uint256[] bundleAmounts;
        uint256 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
        uint256 lastFeeAccrual; // Timestamp of last AUM fee accrual
    }

    struct EqualIndexStorage {
        uint256 indexCount;
        mapping(uint256 => Index) indexes;
        mapping(uint256 => mapping(address => uint256)) vaultBalances; // indexId -> asset -> balance
        bool flashReentrancy;
        address protocolFeeReceiver;
        mapping(uint256 => mapping(bytes32 => Types.ActionFeeConfig)) actionFees;
        address foundationAddress; // AUM fee recipient
        uint256 annualFeeBps; // Annual fee rate in basis points (100 = 1%)
    }

    event IndexCreated(
        uint256 indexed indexId,
        address token,
        address[] assets,
        uint256[] bundleAmounts,
        uint256 flashFeeBps
    );
    event Minted(uint256 indexed indexId, address indexed user, uint256 units, uint256[] assetsIn);
    event Burned(uint256 indexed indexId, address indexed user, uint256 units, uint256[] assetsOut);
    event FlashLoaned(
        uint256 indexed indexId,
        address indexed receiver,
        uint256 units,
        uint256[] loanAmounts,
        uint256[] fees
    );
    event Paused(uint256 indexed indexId, bool paused);
    event ProtocolFeeReceiverUpdated(address indexed newReceiver);
    event FoundationAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event AnnualFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event AumFeeAccrued(uint256 indexed indexId, uint256 feeShares, uint256 timestamp);

    function s() internal pure returns (EqualIndexStorage storage es) {
        bytes32 position = EQUAL_INDEX_STORAGE_POSITION;
        assembly {
            es.slot := position
        }
    }

    function calcRequired(uint256 units, uint256[] storage bundle) internal view returns (uint256[] memory out) {
        uint256 len = bundle.length;
        out = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = Math.mulDiv(bundle[i], units, INDEX_SCALE);
        }
    }
}

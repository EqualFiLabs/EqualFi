// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Diamond storage primitives for the isolated GMX-style perps module.
library LibPerpsStorage {
    bytes32 internal constant PERPS_STORAGE_POSITION = keccak256("equalis.perps.gmxstyle.storage.v1");

    struct PerpsMarket {
        bytes32 marketId;
        uint256 collateralPoolId;
        address collateralAsset;
        address indexAsset;
        bool longEnabled;
        bool shortEnabled;
        address oracleAdapter;
        uint32 maxStaleness;
        uint32 maxDeviationBps;
        uint32 maxLeverageBps;
        uint32 initialMarginBps;
        uint32 maintenanceMarginBps;
        uint32 liquidationIncentiveBpsMax;
        uint256 maxOpenInterest;
        uint256 maxLongOpenInterest;
        uint256 maxShortOpenInterest;
        uint256 maxSkewAbs;
        uint32 takerFeeBps;
        uint32 makerFeeBps;
        uint32 maxFundingVelocityBpsPerDay;
        bool pauseIncrease;
        bool pauseDecrease;
        bool pauseLiquidation;
        bool pauseSync;
        bool exists;
    }

    struct PerpsMarketState {
        uint256 openInterestLong;
        uint256 openInterestShort;
        int256 skew;
        int256 cumulativeFundingLongX18;
        int256 cumulativeFundingShortX18;
        uint64 lastFundingTs;
        uint256 insuranceBalance;
        uint256 insuranceTarget;
        uint256 badDebt;
        uint256 lpFeeIndexX18;
        uint256 protocolFeesAccrued;
        uint256 reservedCollateral;
        uint256 realizedPnlOut;
        uint256 realizedPnlIn;
    }

    struct PerpsAccount {
        bytes32 accountId;
        bytes32 positionKey;
        uint256 positionTokenId;
        uint64 nonce;
        bool exists;
    }

    struct PerpsPosition {
        bool isLong;
        uint256 sizeUsdX18;
        uint256 collateralAmount;
        uint256 entryPriceX18;
        int256 entryFundingX18;
        int256 realizedPnlX18;
        uint64 lastIncreaseTs;
    }

    struct PerpsDomainState {
        uint256 isolatedTrackedBalance;
        uint256 isolatedLiabilities;
        uint256 isolatedEncumbered;
    }

    struct PerpsIntent {
        bytes32 marketId;
        bytes32 accountId;
        uint8 action;
        bool isLong;
        uint256 sizeDeltaUsdX18;
        int256 collateralDelta;
        uint256 limitPriceX18;
        uint256 maxSlippageBps;
        uint256 maxExecutorFee;
        uint64 nonce;
        uint64 deadline;
    }

    struct SettlementDelta {
        bytes32 marketId;
        bytes32 accountId;
        int256 collateralInOut;
        int256 realizedPnl;
        int256 fundingPaid;
        uint256 takerFee;
        uint256 lpFee;
        uint256 protocolFee;
        uint256 executorFee;
        uint256 liquidationProtocolFee;
        uint256 liquidatorReward;
        uint256 insuranceUsed;
        uint256 badDebtDelta;
    }

    struct Layout {
        mapping(bytes32 => PerpsMarket) markets;
        mapping(bytes32 => PerpsMarketState) marketState;
        mapping(bytes32 => PerpsAccount) accounts;
        mapping(bytes32 => mapping(bytes32 => mapping(bool => PerpsPosition))) positions;
        mapping(bytes32 => bool) canceledIntents;
        mapping(bytes32 => uint64) minValidNonce;
        PerpsDomainState domainState;
        uint256 marketCount;
        uint256 accountCount;
    }

    function s() internal pure returns (Layout storage ps) {
        bytes32 position = PERPS_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }
}

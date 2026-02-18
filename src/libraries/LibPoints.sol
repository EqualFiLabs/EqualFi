// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

library LibPoints {
    bytes32 internal constant STORAGE_POSITION = keccak256("equallend.points.storage");
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant BURN_REASON_REDEEM = keccak256("POINTS_BURN_REDEEM");

    bytes32 internal constant ACTION_DEPOSIT_TO_POSITION = keccak256("POINTS_DEPOSIT_TO_POSITION");
    bytes32 internal constant ACTION_MINT_POSITION_WITH_DEPOSIT = keccak256("POINTS_MINT_POSITION_WITH_DEPOSIT");
    bytes32 internal constant ACTION_BORROW_ROLLING = keccak256("POINTS_BORROW_ROLLING");
    bytes32 internal constant ACTION_BORROW_FIXED = keccak256("POINTS_BORROW_FIXED");
    bytes32 internal constant ACTION_REPAY_ROLLING = keccak256("POINTS_REPAY_ROLLING");
    bytes32 internal constant ACTION_REPAY_FIXED = keccak256("POINTS_REPAY_FIXED");
    bytes32 internal constant ACTION_FLASH_LOAN = keccak256("POINTS_FLASH_LOAN");
    bytes32 internal constant ACTION_DERIVATIVE_CREATE_OPTION = keccak256("POINTS_DERIVATIVE_CREATE_OPTION");
    bytes32 internal constant ACTION_DERIVATIVE_CREATE_FUTURES = keccak256("POINTS_DERIVATIVE_CREATE_FUTURES");
    bytes32 internal constant ACTION_DERIVATIVE_CREATE_AMM_AUCTION = keccak256("POINTS_DERIVATIVE_CREATE_AMM_AUCTION");
    bytes32 internal constant ACTION_DIRECT_POST_LENDER_OFFER = keccak256("POINTS_DIRECT_POST_LENDER_OFFER");
    bytes32 internal constant ACTION_DIRECT_POST_BORROWER_OFFER = keccak256("POINTS_DIRECT_POST_BORROWER_OFFER");
    bytes32 internal constant ACTION_DIRECT_POST_RATIO_LENDER_OFFER = keccak256("POINTS_DIRECT_POST_RATIO_LENDER_OFFER");
    bytes32 internal constant ACTION_DIRECT_POST_RATIO_BORROWER_OFFER = keccak256("POINTS_DIRECT_POST_RATIO_BORROWER_OFFER");
    bytes32 internal constant ACTION_DIRECT_POST_ROLLING_LENDER_OFFER = keccak256("POINTS_DIRECT_POST_ROLLING_LENDER_OFFER");
    bytes32 internal constant ACTION_DIRECT_POST_ROLLING_BORROWER_OFFER = keccak256("POINTS_DIRECT_POST_ROLLING_BORROWER_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT_LENDER_OFFER = keccak256("POINTS_DIRECT_ACCEPT_LENDER_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT_BORROWER_OFFER = keccak256("POINTS_DIRECT_ACCEPT_BORROWER_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT_RATIO_LENDER_OFFER = keccak256("POINTS_DIRECT_ACCEPT_RATIO_LENDER_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT_RATIO_BORROWER_OFFER = keccak256("POINTS_DIRECT_ACCEPT_RATIO_BORROWER_OFFER");
    bytes32 internal constant ACTION_DIRECT_ACCEPT_ROLLING_OFFER = keccak256("POINTS_DIRECT_ACCEPT_ROLLING_OFFER");
    bytes32 internal constant ACTION_ROLLING_PAYMENT = keccak256("POINTS_ROLLING_PAYMENT");
    bytes32 internal constant ACTION_SWAP_AMM_AUCTION = keccak256("POINTS_SWAP_AMM_AUCTION");
    bytes32 internal constant ACTION_SWAP_MAM_CURVE = keccak256("POINTS_SWAP_MAM_CURVE");
    bytes32 internal constant ACTION_SWAP_COMMUNITY_AUCTION = keccak256("POINTS_SWAP_COMMUNITY_AUCTION");
    bytes32 internal constant ACTION_INDEX_MINT = keccak256("POINTS_INDEX_MINT");
    bytes32 internal constant ACTION_INDEX_BURN = keccak256("POINTS_INDEX_BURN");
    bytes32 internal constant ACTION_INDEX_MINT_POSITION = keccak256("POINTS_INDEX_MINT_POSITION");
    bytes32 internal constant ACTION_INDEX_BURN_POSITION = keccak256("POINTS_INDEX_BURN_POSITION");

    struct PointsStorage {
        mapping(address => uint256) balances;
        mapping(bytes32 => uint256) pointsPerAction;
        mapping(bytes32 => uint256) accrualCooldownSecs;
        uint256 dailyPointsCap;
        mapping(address => uint64) lastAccrualDay;
        mapping(address => uint256) accruedOnDay;
        mapping(address => mapping(bytes32 => uint64)) lastAccrualTs;
        mapping(address => uint256) earned;
        mapping(address => uint256) burned;
        uint256 totalEarned;
        uint256 totalBurned;
        address redemptionToken;
        bool redemptionEnabled;
        uint64 redemptionEpochLengthSecs;
        uint256 tokensPerPointWad;
        uint256 redemptionGlobalMintCap;
        uint256 redemptionTotalMinted;
        uint256 redemptionEpochMintCap;
        mapping(uint64 => uint256) redemptionMintedByEpoch;
    }

    event PointsAccrued(address indexed user, bytes32 indexed actionType, uint256 amount);
    event PointsBurned(address indexed user, bytes32 indexed reason, uint256 amount);
    event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);
    event PointsDailyCapUpdated(uint256 newDailyCap);
    event PointsAccrualCooldownUpdated(bytes32 indexed actionType, uint256 cooldownSecs);
    event PointsRedemptionTokenUpdated(address indexed token);
    event PointsRedemptionEnabledUpdated(bool enabled);
    event PointsRedemptionRateUpdated(uint256 tokensPerPointWad);
    event PointsRedemptionGlobalMintCapUpdated(uint256 newCap);
    event PointsRedemptionEpochConfigUpdated(uint64 epochLengthSecs, uint256 epochMintCap);
    event PointsRedemptionRecorded(address indexed user, uint256 pointsIn, uint256 tokenOut);

    error Points_InsufficientBalance();
    error Points_RedemptionDisabled();
    error Points_RedemptionTokenNotSet();
    error Points_RedemptionOutputZero();
    error Points_GlobalMintCapExceeded();
    error Points_EpochMintCapExceeded();

    function s() internal pure returns (PointsStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            ps.slot := slot
        }
    }

    function accrue(address user, bytes32 actionType) internal {
        PointsStorage storage ps = s();
        uint256 points = ps.pointsPerAction[actionType];
        if (points == 0) return;

        uint256 cooldownSecs = ps.accrualCooldownSecs[actionType];
        if (cooldownSecs > 0) {
            uint64 lastTs = ps.lastAccrualTs[user][actionType];
            if (lastTs != 0 && block.timestamp < uint256(lastTs) + cooldownSecs) {
                return;
            }
        }

        uint256 credited = points;
        uint256 dailyCap = ps.dailyPointsCap;
        if (dailyCap > 0) {
            uint64 dayKey = uint64(block.timestamp / 1 days);
            if (ps.lastAccrualDay[user] != dayKey) {
                ps.lastAccrualDay[user] = dayKey;
                ps.accruedOnDay[user] = 0;
            }

            uint256 accrued = ps.accruedOnDay[user];
            if (accrued >= dailyCap) return;
            uint256 remaining = dailyCap - accrued;
            if (credited > remaining) {
                credited = remaining;
            }
            ps.accruedOnDay[user] = accrued + credited;
        }

        if (credited == 0) return;
        ps.lastAccrualTs[user][actionType] = uint64(block.timestamp);
        ps.earned[user] += credited;
        ps.totalEarned += credited;
        ps.balances[user] += credited;
        emit PointsAccrued(user, actionType, credited);
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) internal {
        s().pointsPerAction[actionType] = amount;
        emit PointsPerActionUpdated(actionType, amount);
    }

    function setDailyPointsCap(uint256 amount) internal {
        s().dailyPointsCap = amount;
        emit PointsDailyCapUpdated(amount);
    }

    function setAccrualCooldown(bytes32 actionType, uint256 cooldownSecs) internal {
        s().accrualCooldownSecs[actionType] = cooldownSecs;
        emit PointsAccrualCooldownUpdated(actionType, cooldownSecs);
    }

    function balanceOf(address user) internal view returns (uint256) {
        return s().balances[user];
    }

    function earnedOf(address user) internal view returns (uint256) {
        return s().earned[user];
    }

    function burnedOf(address user) internal view returns (uint256) {
        return s().burned[user];
    }

    function totalEarned() internal view returns (uint256) {
        return s().totalEarned;
    }

    function totalBurned() internal view returns (uint256) {
        return s().totalBurned;
    }

    function pointsForAction(bytes32 actionType) internal view returns (uint256) {
        return s().pointsPerAction[actionType];
    }

    function accrualCooldownForAction(bytes32 actionType) internal view returns (uint256) {
        return s().accrualCooldownSecs[actionType];
    }

    function dailyPointsCap() internal view returns (uint256) {
        return s().dailyPointsCap;
    }

    function accruedToday(address user) internal view returns (uint256) {
        PointsStorage storage ps = s();
        uint64 dayKey = uint64(block.timestamp / 1 days);
        if (ps.lastAccrualDay[user] != dayKey) {
            return 0;
        }
        return ps.accruedOnDay[user];
    }

    function lastAccruedAt(address user, bytes32 actionType) internal view returns (uint256) {
        return s().lastAccrualTs[user][actionType];
    }

    function burn(address user, uint256 amount, bytes32 reason) internal {
        if (amount == 0) return;
        PointsStorage storage ps = s();
        uint256 bal = ps.balances[user];
        if (amount > bal) revert Points_InsufficientBalance();

        ps.balances[user] = bal - amount;
        ps.burned[user] += amount;
        ps.totalBurned += amount;
        emit PointsBurned(user, reason, amount);
    }

    function setRedemptionToken(address token) internal {
        s().redemptionToken = token;
        emit PointsRedemptionTokenUpdated(token);
    }

    function setRedemptionEnabled(bool enabled) internal {
        s().redemptionEnabled = enabled;
        emit PointsRedemptionEnabledUpdated(enabled);
    }

    function setRedemptionRate(uint256 tokensPerPointWad_) internal {
        s().tokensPerPointWad = tokensPerPointWad_;
        emit PointsRedemptionRateUpdated(tokensPerPointWad_);
    }

    function setRedemptionGlobalMintCap(uint256 newCap) internal {
        s().redemptionGlobalMintCap = newCap;
        emit PointsRedemptionGlobalMintCapUpdated(newCap);
    }

    function setRedemptionEpochConfig(uint64 epochLengthSecs, uint256 epochMintCap) internal {
        PointsStorage storage ps = s();
        ps.redemptionEpochLengthSecs = epochLengthSecs;
        ps.redemptionEpochMintCap = epochMintCap;
        emit PointsRedemptionEpochConfigUpdated(epochLengthSecs, epochMintCap);
    }

    function previewRedemption(uint256 pointsIn) internal view returns (uint256) {
        return (pointsIn * s().tokensPerPointWad) / WAD;
    }

    function consumeRedemption(address user, uint256 pointsIn) internal returns (address token, uint256 tokenOut) {
        PointsStorage storage ps = s();
        if (!ps.redemptionEnabled) revert Points_RedemptionDisabled();

        token = ps.redemptionToken;
        if (token == address(0)) revert Points_RedemptionTokenNotSet();

        tokenOut = (pointsIn * ps.tokensPerPointWad) / WAD;
        if (tokenOut == 0) revert Points_RedemptionOutputZero();

        uint256 globalCap = ps.redemptionGlobalMintCap;
        if (globalCap > 0 && ps.redemptionTotalMinted + tokenOut > globalCap) {
            revert Points_GlobalMintCapExceeded();
        }

        uint64 epochLength = ps.redemptionEpochLengthSecs;
        if (epochLength > 0) {
            uint256 epochCap = ps.redemptionEpochMintCap;
            if (epochCap > 0) {
                uint64 epochId = uint64(block.timestamp / epochLength);
                if (ps.redemptionMintedByEpoch[epochId] + tokenOut > epochCap) {
                    revert Points_EpochMintCapExceeded();
                }
                ps.redemptionMintedByEpoch[epochId] += tokenOut;
            }
        }

        burn(user, pointsIn, BURN_REASON_REDEEM);
        ps.redemptionTotalMinted += tokenOut;
        emit PointsRedemptionRecorded(user, pointsIn, tokenOut);
    }

    function redemptionToken() internal view returns (address) {
        return s().redemptionToken;
    }

    function redemptionEnabled() internal view returns (bool) {
        return s().redemptionEnabled;
    }

    function redemptionRate() internal view returns (uint256) {
        return s().tokensPerPointWad;
    }

    function redemptionGlobalMintCap() internal view returns (uint256) {
        return s().redemptionGlobalMintCap;
    }

    function redemptionTotalMinted() internal view returns (uint256) {
        return s().redemptionTotalMinted;
    }

    function redemptionEpochLength() internal view returns (uint64) {
        return s().redemptionEpochLengthSecs;
    }

    function redemptionEpochMintCap() internal view returns (uint256) {
        return s().redemptionEpochMintCap;
    }

    function redemptionMintedInCurrentEpoch() internal view returns (uint256) {
        PointsStorage storage ps = s();
        uint64 epochLength = ps.redemptionEpochLengthSecs;
        if (epochLength == 0) return 0;
        uint64 epochId = uint64(block.timestamp / epochLength);
        return ps.redemptionMintedByEpoch[epochId];
    }
}

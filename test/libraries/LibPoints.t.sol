// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";

contract LibPointsHarness {
    function keyForAccount(address account) external pure returns (bytes32) {
        return LibPoints.keyForAccount(account);
    }

    function accrue(address user, bytes32 actionType) external {
        LibPoints.accrue(user, actionType);
    }

    function accrueForKey(bytes32 pointsKey, bytes32 actionType) external {
        LibPoints.accrue(pointsKey, actionType);
    }

    function accrueToKey(address account, bytes32 pointsKey, bytes32 actionType) external {
        LibPoints.accrueToKey(account, pointsKey, actionType);
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function getPoints(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function getPointsForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.balanceOf(pointsKey);
    }

    function getPointsEarned(address user) external view returns (uint256) {
        return LibPoints.earnedOf(user);
    }

    function getPointsEarnedForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.earnedOf(pointsKey);
    }

    function getPointsBurned(address user) external view returns (uint256) {
        return LibPoints.burnedOf(user);
    }

    function getPointsBurnedForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.burnedOf(pointsKey);
    }

    function getTotalPointsEarned() external view returns (uint256) {
        return LibPoints.totalEarned();
    }

    function getTotalPointsBurned() external view returns (uint256) {
        return LibPoints.totalBurned();
    }

    function getPointsPerAction(bytes32 actionType) external view returns (uint256) {
        return LibPoints.pointsForAction(actionType);
    }

    function setDailyPointsCap(uint256 amount) external {
        LibPoints.setDailyPointsCap(amount);
    }

    function setAccrualCooldown(bytes32 actionType, uint256 cooldownSecs) external {
        LibPoints.setAccrualCooldown(actionType, cooldownSecs);
    }

    function getDailyPointsCap() external view returns (uint256) {
        return LibPoints.dailyPointsCap();
    }

    function getAccrualCooldown(bytes32 actionType) external view returns (uint256) {
        return LibPoints.accrualCooldownForAction(actionType);
    }

    function getAccruedToday(address user) external view returns (uint256) {
        return LibPoints.accruedToday(user);
    }

    function getAccruedTodayForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.accruedToday(pointsKey);
    }

    function getLastAccruedAt(address user, bytes32 actionType) external view returns (uint256) {
        return LibPoints.lastAccruedAt(user, actionType);
    }

    function getLastAccruedAtForKey(bytes32 pointsKey, bytes32 actionType) external view returns (uint256) {
        return LibPoints.lastAccruedAt(pointsKey, actionType);
    }

    function burn(address user, uint256 amount, bytes32 reason) external {
        LibPoints.burn(user, amount, reason);
    }

    function burnForKey(bytes32 pointsKey, uint256 amount, bytes32 reason) external {
        LibPoints.burn(pointsKey, amount, reason);
    }

    function setRedemptionToken(address token) external {
        LibPoints.setRedemptionToken(token);
    }

    function setRedemptionEnabled(bool enabled) external {
        LibPoints.setRedemptionEnabled(enabled);
    }

    function setRedemptionRate(uint256 tokensPerPointWad) external {
        LibPoints.setRedemptionRate(tokensPerPointWad);
    }

    function setRedemptionGlobalMintCap(uint256 newCap) external {
        LibPoints.setRedemptionGlobalMintCap(newCap);
    }

    function setRedemptionEpochConfig(uint64 epochLengthSecs, uint256 epochMintCap) external {
        LibPoints.setRedemptionEpochConfig(epochLengthSecs, epochMintCap);
    }

    function consumeRedemption(address user, uint256 pointsIn) external returns (address token, uint256 tokenOut) {
        return LibPoints.consumeRedemption(user, pointsIn);
    }

    function consumeRedemptionForKey(bytes32 pointsKey, uint256 pointsIn)
        external
        returns (address token, uint256 tokenOut)
    {
        return LibPoints.consumeRedemption(pointsKey, pointsIn);
    }

    function previewRedemption(uint256 pointsIn) external view returns (uint256 tokenOut) {
        return LibPoints.previewRedemption(pointsIn);
    }

    function redemptionToken() external view returns (address) {
        return LibPoints.redemptionToken();
    }

    function redemptionEnabled() external view returns (bool) {
        return LibPoints.redemptionEnabled();
    }

    function redemptionRate() external view returns (uint256) {
        return LibPoints.redemptionRate();
    }

    function redemptionGlobalMintCap() external view returns (uint256) {
        return LibPoints.redemptionGlobalMintCap();
    }

    function redemptionTotalMinted() external view returns (uint256) {
        return LibPoints.redemptionTotalMinted();
    }

    function redemptionEpochLength() external view returns (uint64) {
        return LibPoints.redemptionEpochLength();
    }

    function redemptionEpochMintCap() external view returns (uint256) {
        return LibPoints.redemptionEpochMintCap();
    }

    function redemptionMintedInCurrentEpoch() external view returns (uint256) {
        return LibPoints.redemptionMintedInCurrentEpoch();
    }
}

contract LibPointsTest is Test {
    event PointsAccrued(bytes32 indexed pointsKey, bytes32 indexed actionType, uint256 amount);
    event PointsBurned(bytes32 indexed pointsKey, bytes32 indexed reason, uint256 amount);
    event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);
    event PointsDailyCapUpdated(uint256 newDailyCap);
    event PointsAccrualCooldownUpdated(bytes32 indexed actionType, uint256 cooldownSecs);
    event PointsRedemptionTokenUpdated(address indexed token);
    event PointsRedemptionEnabledUpdated(bool enabled);
    event PointsRedemptionRateUpdated(uint256 tokensPerPointWad);
    event PointsRedemptionGlobalMintCapUpdated(uint256 newCap);
    event PointsRedemptionEpochConfigUpdated(uint64 epochLengthSecs, uint256 epochMintCap);
    event PointsRedemptionRecorded(bytes32 indexed pointsKey, uint256 pointsIn, uint256 tokenOut);

    LibPointsHarness internal h;

    bytes32 internal constant ACTION_A = keccak256("POINTS_ACTION_A");
    bytes32 internal constant ACTION_B = keccak256("POINTS_ACTION_B");
    bytes32 internal constant ACTION_C = keccak256("POINTS_ACTION_C");

    function setUp() public {
        h = new LibPointsHarness();
    }

    function test_setPointsPerAction_roundTripAndEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PointsPerActionUpdated(ACTION_A, 42);
        h.setPointsPerAction(ACTION_A, 42);

        assertEq(h.getPointsPerAction(ACTION_A), 42);
    }

    function test_setDailyPointsCap_roundTripAndEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsDailyCapUpdated(100);
        h.setDailyPointsCap(100);
        assertEq(h.getDailyPointsCap(), 100);
    }

    function test_setAccrualCooldown_roundTripAndEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PointsAccrualCooldownUpdated(ACTION_A, 1 hours);
        h.setAccrualCooldown(ACTION_A, 1 hours);
        assertEq(h.getAccrualCooldown(ACTION_A), 1 hours);
    }

    /// **Feature: point-system, Property 1: Accrual increments by configured amount**
    function testFuzz_accrue_incrementsByConfiguredAmount(address user, bytes32 actionType, uint256 points) public {
        points = bound(points, 1, type(uint128).max);
        h.setPointsPerAction(actionType, points);

        uint256 beforeBal = h.getPoints(user);
        h.accrue(user, actionType);
        uint256 afterBal = h.getPoints(user);

        assertEq(afterBal - beforeBal, points);
    }

    /// **Feature: point-system, Property 2: Cumulative additivity**
    function testFuzz_accrue_isCumulative(
        address user,
        uint256 pointsA,
        uint256 pointsB,
        uint256 pointsC,
        uint8 countA,
        uint8 countB,
        uint8 countC
    ) public {
        pointsA = bound(pointsA, 1, type(uint64).max);
        pointsB = bound(pointsB, 1, type(uint64).max);
        pointsC = bound(pointsC, 1, type(uint64).max);

        h.setPointsPerAction(ACTION_A, pointsA);
        h.setPointsPerAction(ACTION_B, pointsB);
        h.setPointsPerAction(ACTION_C, pointsC);

        uint256 nA = uint256(bound(countA, 0, 32));
        uint256 nB = uint256(bound(countB, 0, 32));
        uint256 nC = uint256(bound(countC, 0, 32));

        for (uint256 i = 0; i < nA; i++) h.accrue(user, ACTION_A);
        for (uint256 i = 0; i < nB; i++) h.accrue(user, ACTION_B);
        for (uint256 i = 0; i < nC; i++) h.accrue(user, ACTION_C);

        uint256 expected = (nA * pointsA) + (nB * pointsB) + (nC * pointsC);
        assertEq(h.getPoints(user), expected);
    }

    /// **Feature: point-system, Property 5: Zero-config disables accrual**
    function testFuzz_accrue_zeroConfigDoesNotChangeBalance(address user, bytes32 actionType) public {
        assertEq(h.getPointsPerAction(actionType), 0);
        uint256 beforeBal = h.getPoints(user);

        vm.recordLogs();
        h.accrue(user, actionType);

        assertEq(h.getPoints(user), beforeBal);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// **Feature: point-system, Property 6: Accrual event emission**
    function testFuzz_accrue_emitsEvent(address user, bytes32 actionType, uint256 points) public {
        points = bound(points, 1, type(uint128).max);
        h.setPointsPerAction(actionType, points);
        bytes32 pointsKey = h.keyForAccount(user);

        vm.expectEmit(true, true, false, true);
        emit PointsAccrued(pointsKey, actionType, points);
        h.accrue(user, actionType);
    }

    function test_balanceOf_freshAddressReturnsZero() public {
        assertEq(h.getPoints(address(0xBEEF)), 0);
    }

    function test_accrue_addressZero_works() public {
        h.setPointsPerAction(ACTION_A, 7);
        h.accrue(address(0), ACTION_A);
        assertEq(h.getPoints(address(0)), 7);
    }

    function test_accrue_tracksEarnedAndTotalEarned() public {
        address user = address(0xA11CE);
        h.setPointsPerAction(ACTION_A, 4);
        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);

        assertEq(h.getPoints(user), 8);
        assertEq(h.getPointsEarned(user), 8);
        assertEq(h.getPointsBurned(user), 0);
        assertEq(h.getTotalPointsEarned(), 8);
        assertEq(h.getTotalPointsBurned(), 0);
    }

    function test_burn_reducesBalanceAndTracksBurnTotals() public {
        address user = address(0xBEEF);
        bytes32 reason = keccak256("POINTS_BURN_TEST");
        bytes32 pointsKey = h.keyForAccount(user);
        h.setPointsPerAction(ACTION_A, 15);
        h.accrue(user, ACTION_A);

        vm.expectEmit(true, true, false, true);
        emit PointsBurned(pointsKey, reason, 9);
        h.burn(user, 9, reason);

        assertEq(h.getPoints(user), 6);
        assertEq(h.getPointsEarned(user), 15);
        assertEq(h.getPointsBurned(user), 9);
        assertEq(h.getTotalPointsEarned(), 15);
        assertEq(h.getTotalPointsBurned(), 9);
    }

    function test_burn_revertsWhenInsufficientBalance() public {
        h.setPointsPerAction(ACTION_A, 3);
        h.accrue(address(this), ACTION_A);

        vm.expectRevert(LibPoints.Points_InsufficientBalance.selector);
        h.burn(address(this), 4, keccak256("POINTS_BURN_TOO_MUCH"));
    }

    function test_redemptionConfig_settersRoundTripAndEvents() public {
        vm.expectEmit(true, false, false, true);
        emit PointsRedemptionTokenUpdated(address(0xCAFE));
        h.setRedemptionToken(address(0xCAFE));

        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionEnabledUpdated(true);
        h.setRedemptionEnabled(true);

        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionRateUpdated(2e18);
        h.setRedemptionRate(2e18);

        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionGlobalMintCapUpdated(1_000_000 ether);
        h.setRedemptionGlobalMintCap(1_000_000 ether);

        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionEpochConfigUpdated(1 days, 10_000 ether);
        h.setRedemptionEpochConfig(1 days, 10_000 ether);

        assertEq(h.redemptionToken(), address(0xCAFE));
        assertEq(h.redemptionEnabled(), true);
        assertEq(h.redemptionRate(), 2e18);
        assertEq(h.redemptionGlobalMintCap(), 1_000_000 ether);
        assertEq(h.redemptionEpochLength(), 1 days);
        assertEq(h.redemptionEpochMintCap(), 10_000 ether);
    }

    function test_previewRedemption_usesWadRate() public {
        h.setRedemptionRate(15e17); // 1.5 tokens / point
        assertEq(h.previewRedemption(4), 6);
    }

    function test_consumeRedemption_revertsWhenDisabled() public {
        h.setPointsPerAction(ACTION_A, 10);
        h.accrue(address(this), ACTION_A);
        h.setRedemptionToken(address(0xCAFE));
        h.setRedemptionRate(1e18);

        vm.expectRevert(LibPoints.Points_RedemptionDisabled.selector);
        h.consumeRedemption(address(this), 5);
    }

    function test_consumeRedemption_revertsWhenTokenNotSet() public {
        h.setPointsPerAction(ACTION_A, 10);
        h.accrue(address(this), ACTION_A);
        h.setRedemptionEnabled(true);
        h.setRedemptionRate(1e18);

        vm.expectRevert(LibPoints.Points_RedemptionTokenNotSet.selector);
        h.consumeRedemption(address(this), 5);
    }

    function test_consumeRedemption_revertsWhenRateProducesZeroOutput() public {
        h.setPointsPerAction(ACTION_A, 10);
        h.accrue(address(this), ACTION_A);
        h.setRedemptionEnabled(true);
        h.setRedemptionToken(address(0xCAFE));

        vm.expectRevert(LibPoints.Points_RedemptionOutputZero.selector);
        h.consumeRedemption(address(this), 5);
    }

    function test_consumeRedemption_burnsPointsAndTracksMinted() public {
        h.setPointsPerAction(ACTION_A, 12);
        h.accrue(address(this), ACTION_A);

        h.setRedemptionEnabled(true);
        h.setRedemptionToken(address(0xCAFE));
        h.setRedemptionRate(2e18); // 2 tokens per point
        bytes32 pointsKey = h.keyForAccount(address(this));

        vm.expectEmit(true, true, false, true);
        emit PointsBurned(pointsKey, keccak256("POINTS_BURN_REDEEM"), 5);
        vm.expectEmit(true, false, false, true);
        emit PointsRedemptionRecorded(pointsKey, 5, 10);
        (address token, uint256 tokenOut) = h.consumeRedemption(address(this), 5);

        assertEq(token, address(0xCAFE));
        assertEq(tokenOut, 10);
        assertEq(h.getPoints(address(this)), 7);
        assertEq(h.getPointsBurned(address(this)), 5);
        assertEq(h.redemptionTotalMinted(), 10);
    }

    function test_consumeRedemption_respectsGlobalMintCap() public {
        h.setPointsPerAction(ACTION_A, 30);
        h.accrue(address(this), ACTION_A);

        h.setRedemptionEnabled(true);
        h.setRedemptionToken(address(0xCAFE));
        h.setRedemptionRate(1e18);
        h.setRedemptionGlobalMintCap(20);

        h.consumeRedemption(address(this), 10);
        h.consumeRedemption(address(this), 10);

        vm.expectRevert(LibPoints.Points_GlobalMintCapExceeded.selector);
        h.consumeRedemption(address(this), 1);
    }

    function test_consumeRedemption_respectsEpochMintCapAndResetsByEpoch() public {
        h.setPointsPerAction(ACTION_A, 50);
        h.accrue(address(this), ACTION_A);

        h.setRedemptionEnabled(true);
        h.setRedemptionToken(address(0xCAFE));
        h.setRedemptionRate(1e18);
        h.setRedemptionEpochConfig(1 days, 20);

        h.consumeRedemption(address(this), 12);
        assertEq(h.redemptionMintedInCurrentEpoch(), 12);

        vm.expectRevert(LibPoints.Points_EpochMintCapExceeded.selector);
        h.consumeRedemption(address(this), 9);

        vm.warp(block.timestamp + 1 days);
        assertEq(h.redemptionMintedInCurrentEpoch(), 0);
        h.consumeRedemption(address(this), 20);
        assertEq(h.redemptionMintedInCurrentEpoch(), 20);
    }

    function test_accrue_dailyCapClampsWithPartialCredit() public {
        address user = address(0xA11CE);
        h.setPointsPerAction(ACTION_A, 10);
        h.setDailyPointsCap(25);

        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);

        assertEq(h.getPoints(user), 25);
        assertEq(h.getAccruedToday(user), 25);
    }

    function test_accrue_dailyCapResetsNextDay() public {
        address user = address(0xBEEF);
        h.setPointsPerAction(ACTION_A, 10);
        h.setDailyPointsCap(10);

        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);
        assertEq(h.getPoints(user), 10);
        assertEq(h.getAccruedToday(user), 10);

        vm.warp(block.timestamp + 1 days);
        assertEq(h.getAccruedToday(user), 0);
        h.accrue(user, ACTION_A);

        assertEq(h.getPoints(user), 20);
        assertEq(h.getAccruedToday(user), 10);
    }

    function test_accrue_cooldownBlocksRapidRepeatAndAllowsAfterWindow() public {
        address user = address(0xABCD);
        h.setPointsPerAction(ACTION_A, 9);
        h.setAccrualCooldown(ACTION_A, 1 hours);

        h.accrue(user, ACTION_A);
        assertEq(h.getPoints(user), 9);

        uint256 firstAccrualTs = h.getLastAccruedAt(user, ACTION_A);
        h.accrue(user, ACTION_A);
        assertEq(h.getPoints(user), 9);
        assertEq(h.getLastAccruedAt(user, ACTION_A), firstAccrualTs);

        vm.warp(block.timestamp + 1 hours);
        h.accrue(user, ACTION_A);
        assertEq(h.getPoints(user), 18);
        assertEq(h.getLastAccruedAt(user, ACTION_A), block.timestamp);
    }

    function test_accrue_cooldownIsPerActionNotGlobal() public {
        address user = address(0xC0FFEE);
        h.setPointsPerAction(ACTION_A, 3);
        h.setPointsPerAction(ACTION_B, 5);
        h.setAccrualCooldown(ACTION_A, 1 days);
        h.setAccrualCooldown(ACTION_B, 1 days);

        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_A);
        h.accrue(user, ACTION_B);

        assertEq(h.getPoints(user), 8);
    }

    function test_accrue_borrowAndRepayCooldownsApplyIndependently() public {
        address user = address(0xD00D);
        h.setPointsPerAction(LibPoints.ACTION_BORROW_ROLLING, 10);
        h.setPointsPerAction(LibPoints.ACTION_REPAY_ROLLING, 6);
        h.setAccrualCooldown(LibPoints.ACTION_BORROW_ROLLING, 1 days);
        h.setAccrualCooldown(LibPoints.ACTION_REPAY_ROLLING, 2 days);

        h.accrue(user, LibPoints.ACTION_BORROW_ROLLING);
        h.accrue(user, LibPoints.ACTION_REPAY_ROLLING);
        assertEq(h.getPoints(user), 16);

        h.accrue(user, LibPoints.ACTION_BORROW_ROLLING);
        h.accrue(user, LibPoints.ACTION_REPAY_ROLLING);
        assertEq(h.getPoints(user), 16);

        vm.warp(block.timestamp + 1 days);
        h.accrue(user, LibPoints.ACTION_BORROW_ROLLING);
        h.accrue(user, LibPoints.ACTION_REPAY_ROLLING);
        assertEq(h.getPoints(user), 26);

        vm.warp(block.timestamp + 2 days);
        h.accrue(user, LibPoints.ACTION_REPAY_ROLLING);
        assertEq(h.getPoints(user), 32);
    }

    function test_accrueToKey_dailyCapUsesAccountGuardAcrossMultipleKeys() public {
        address user = address(0xA11CE);
        bytes32 keyA = keccak256("POINTS_KEY_A");
        bytes32 keyB = keccak256("POINTS_KEY_B");
        h.setPointsPerAction(ACTION_A, 7);
        h.setDailyPointsCap(10);

        h.accrueToKey(user, keyA, ACTION_A);
        h.accrueToKey(user, keyB, ACTION_A);

        assertEq(h.getPointsForKey(keyA), 7);
        assertEq(h.getPointsForKey(keyB), 3);
        assertEq(h.getAccruedToday(user), 10);
    }

    function test_accrueToKey_cooldownUsesAccountGuardAcrossMultipleKeys() public {
        address user = address(0xBEEF);
        bytes32 keyA = keccak256("POINTS_KEY_A");
        bytes32 keyB = keccak256("POINTS_KEY_B");
        h.setPointsPerAction(ACTION_A, 5);
        h.setAccrualCooldown(ACTION_A, 1 hours);

        h.accrueToKey(user, keyA, ACTION_A);
        h.accrueToKey(user, keyB, ACTION_A);
        assertEq(h.getPointsForKey(keyA), 5);
        assertEq(h.getPointsForKey(keyB), 0);

        vm.warp(block.timestamp + 1 hours);
        h.accrueToKey(user, keyB, ACTION_A);
        assertEq(h.getPointsForKey(keyB), 5);
    }
}

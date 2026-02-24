// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PointsAdminFacet, Points_ArrayLengthMismatch, Points_IndexPositionWeightInvalid} from
    "../../src/admin/PointsAdminFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";

contract PointsAdminHarness is PointsAdminFacet {
    function setContractOwner(address newOwner) external {
        LibDiamond.setContractOwner(newOwner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function pointsForAction(bytes32 actionType) external view returns (uint256) {
        return LibPoints.pointsForAction(actionType);
    }

    function dailyPointsCap() external view returns (uint256) {
        return LibPoints.dailyPointsCap();
    }

    function accrualCooldown(bytes32 actionType) external view returns (uint256) {
        return LibPoints.accrualCooldownForAction(actionType);
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

    function redemptionEpochLength() external view returns (uint64) {
        return LibPoints.redemptionEpochLength();
    }

    function redemptionEpochMintCap() external view returns (uint256) {
        return LibPoints.redemptionEpochMintCap();
    }
}

contract PointsAdminFacetTest is Test {
    event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);
    event PointsDailyCapUpdated(uint256 newDailyCap);
    event PointsAccrualCooldownUpdated(bytes32 indexed actionType, uint256 cooldownSecs);
    event PointsRedemptionTokenUpdated(address indexed token);
    event PointsRedemptionEnabledUpdated(bool enabled);
    event PointsRedemptionRateUpdated(uint256 tokensPerPointWad);
    event PointsRedemptionGlobalMintCapUpdated(uint256 newCap);
    event PointsRedemptionEpochConfigUpdated(uint64 epochLengthSecs, uint256 epochMintCap);

    PointsAdminHarness internal facet;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);

    function setUp() public {
        facet = new PointsAdminHarness();
        facet.setContractOwner(OWNER);
        facet.setTimelock(TIMELOCK);
    }

    /// **Feature: point-system, Property 3: Governance setter correctness**
    function testFuzz_setPointsPerAction_governanceSetterCorrectness(bytes32 actionType, uint256 amount) public {
        vm.assume(!_isIndexWeightAction(actionType));

        vm.prank(OWNER);
        facet.setPointsPerAction(actionType, amount);

        assertEq(facet.pointsForAction(actionType), amount);
    }

    /// **Feature: point-system, Property 4: Access control revert**
    function testFuzz_setPointsPerAction_nonGovernanceReverts(address caller, bytes32 actionType, uint256 amount)
        public
    {
        vm.assume(caller != OWNER && caller != TIMELOCK);

        vm.prank(caller);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setPointsPerAction(actionType, amount);
    }

    /// **Feature: point-system, Property 7: Config update event emission**
    function testFuzz_setPointsPerAction_emitsConfigUpdateEvent(bytes32 actionType, uint256 amount) public {
        vm.assume(!_isIndexWeightAction(actionType));

        vm.expectEmit(true, false, false, true);
        emit PointsPerActionUpdated(actionType, amount);
        vm.prank(OWNER);
        facet.setPointsPerAction(actionType, amount);
    }

    /// **Feature: point-system, Property 8: Position index actions are strictly higher-weighted**
    function test_setPointsPerAction_revertsWhenIndexWeightsInvalid_single() public {
        _setValidIndexWeights(1, 1, 2, 2);

        vm.prank(OWNER);
        vm.expectRevert(Points_IndexPositionWeightInvalid.selector);
        facet.setPointsPerAction(LibPoints.ACTION_INDEX_MINT, 2);

        vm.prank(OWNER);
        vm.expectRevert(Points_IndexPositionWeightInvalid.selector);
        facet.setPointsPerAction(LibPoints.ACTION_INDEX_BURN_POSITION, 1);
    }

    /// **Feature: point-system, Property 8: Position index actions are strictly higher-weighted**
    function test_setPointsPerActionBatch_revertsWhenIndexWeightsInvalid_finalState() public {
        bytes32[] memory actions = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);

        actions[0] = LibPoints.ACTION_INDEX_MINT;
        actions[1] = LibPoints.ACTION_INDEX_MINT_POSITION;
        amounts[0] = 5;
        amounts[1] = 5;

        vm.prank(OWNER);
        vm.expectRevert(Points_IndexPositionWeightInvalid.selector);
        facet.setPointsPerActionBatch(actions, amounts);
    }

    /// **Feature: point-system, Property 8: Position index actions are strictly higher-weighted**
    function test_setPointsPerActionBatch_validFinalState_isOrderIndependent() public {
        bytes32[] memory actions = new bytes32[](4);
        uint256[] memory amounts = new uint256[](4);

        // Intentionally order wallet actions before position actions.
        actions[0] = LibPoints.ACTION_INDEX_MINT;
        actions[1] = LibPoints.ACTION_INDEX_BURN;
        actions[2] = LibPoints.ACTION_INDEX_MINT_POSITION;
        actions[3] = LibPoints.ACTION_INDEX_BURN_POSITION;
        amounts[0] = 3;
        amounts[1] = 4;
        amounts[2] = 5;
        amounts[3] = 6;

        vm.prank(OWNER);
        facet.setPointsPerActionBatch(actions, amounts);

        assertEq(facet.pointsForAction(LibPoints.ACTION_INDEX_MINT), 3);
        assertEq(facet.pointsForAction(LibPoints.ACTION_INDEX_BURN), 4);
        assertEq(facet.pointsForAction(LibPoints.ACTION_INDEX_MINT_POSITION), 5);
        assertEq(facet.pointsForAction(LibPoints.ACTION_INDEX_BURN_POSITION), 6);
    }

    function test_setPointsPerActionBatch_revertsOnMismatchedArrayLengths() public {
        bytes32[] memory actions = new bytes32[](2);
        uint256[] memory amounts = new uint256[](1);
        actions[0] = keccak256("ACTION_A");
        actions[1] = keccak256("ACTION_B");
        amounts[0] = 1;

        vm.prank(OWNER);
        vm.expectRevert(Points_ArrayLengthMismatch.selector);
        facet.setPointsPerActionBatch(actions, amounts);
    }

    function test_setPointsPerActionBatch_nonGovernanceReverts() public {
        bytes32[] memory actions = new bytes32[](1);
        uint256[] memory amounts = new uint256[](1);
        actions[0] = keccak256("ACTION_A");
        amounts[0] = 10;

        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setPointsPerActionBatch(actions, amounts);
    }

    function test_setPointsPerAction_allowsZeroForNonIndexAction() public {
        bytes32 actionType = keccak256("POINTS_SOME_ACTION");
        vm.prank(OWNER);
        facet.setPointsPerAction(actionType, 0);

        assertEq(facet.pointsForAction(actionType), 0);
    }

    function test_setPointsPerAction_timelockCanCall() public {
        bytes32 actionType = keccak256("POINTS_TIMELOCK_ACTION");
        vm.prank(TIMELOCK);
        facet.setPointsPerAction(actionType, 123);

        assertEq(facet.pointsForAction(actionType), 123);
    }

    function test_setDailyPointsCap_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setDailyPointsCap(777);
        assertEq(facet.dailyPointsCap(), 777);
    }

    function test_setDailyPointsCap_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setDailyPointsCap(1);
    }

    function test_setDailyPointsCap_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsDailyCapUpdated(999);
        vm.prank(OWNER);
        facet.setDailyPointsCap(999);
    }

    function test_setAccrualCooldown_governanceSetterCorrectness() public {
        bytes32 actionType = keccak256("POINTS_TEST_COOLDOWN");
        vm.prank(OWNER);
        facet.setAccrualCooldown(actionType, 2 hours);
        assertEq(facet.accrualCooldown(actionType), 2 hours);
    }

    function test_setAccrualCooldown_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setAccrualCooldown(keccak256("POINTS_TEST_COOLDOWN"), 1);
    }

    function test_setAccrualCooldown_emitsEvent() public {
        bytes32 actionType = keccak256("POINTS_TEST_COOLDOWN");
        vm.expectEmit(true, false, false, true);
        emit PointsAccrualCooldownUpdated(actionType, 6 hours);
        vm.prank(OWNER);
        facet.setAccrualCooldown(actionType, 6 hours);
    }

    function test_setRedemptionToken_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setRedemptionToken(address(0xCAFE));
        assertEq(facet.redemptionToken(), address(0xCAFE));
    }

    function test_setRedemptionToken_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setRedemptionToken(address(0xCAFE));
    }

    function test_setRedemptionToken_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PointsRedemptionTokenUpdated(address(0xCAFE));
        vm.prank(OWNER);
        facet.setRedemptionToken(address(0xCAFE));
    }

    function test_setRedemptionEnabled_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setRedemptionEnabled(true);
        assertEq(facet.redemptionEnabled(), true);
    }

    function test_setRedemptionEnabled_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setRedemptionEnabled(true);
    }

    function test_setRedemptionEnabled_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionEnabledUpdated(true);
        vm.prank(OWNER);
        facet.setRedemptionEnabled(true);
    }

    function test_setRedemptionRate_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setRedemptionRate(2e18);
        assertEq(facet.redemptionRate(), 2e18);
    }

    function test_setRedemptionRate_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setRedemptionRate(2e18);
    }

    function test_setRedemptionRate_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionRateUpdated(2e18);
        vm.prank(OWNER);
        facet.setRedemptionRate(2e18);
    }

    function test_setRedemptionGlobalMintCap_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setRedemptionGlobalMintCap(1_000_000);
        assertEq(facet.redemptionGlobalMintCap(), 1_000_000);
    }

    function test_setRedemptionGlobalMintCap_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setRedemptionGlobalMintCap(1_000_000);
    }

    function test_setRedemptionGlobalMintCap_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionGlobalMintCapUpdated(1234);
        vm.prank(OWNER);
        facet.setRedemptionGlobalMintCap(1234);
    }

    function test_setRedemptionEpochConfig_governanceSetterCorrectness() public {
        vm.prank(OWNER);
        facet.setRedemptionEpochConfig(1 days, 5000);
        assertEq(facet.redemptionEpochLength(), 1 days);
        assertEq(facet.redemptionEpochMintCap(), 5000);
    }

    function test_setRedemptionEpochConfig_nonGovernanceReverts() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setRedemptionEpochConfig(1 days, 5000);
    }

    function test_setRedemptionEpochConfig_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PointsRedemptionEpochConfigUpdated(1 days, 5000);
        vm.prank(OWNER);
        facet.setRedemptionEpochConfig(1 days, 5000);
    }

    function _setValidIndexWeights(uint256 mintPoints, uint256 burnPoints, uint256 mintPositionPoints, uint256 burnPositionPoints)
        internal
    {
        bytes32[] memory actions = new bytes32[](4);
        uint256[] memory amounts = new uint256[](4);

        actions[0] = LibPoints.ACTION_INDEX_MINT;
        actions[1] = LibPoints.ACTION_INDEX_BURN;
        actions[2] = LibPoints.ACTION_INDEX_MINT_POSITION;
        actions[3] = LibPoints.ACTION_INDEX_BURN_POSITION;
        amounts[0] = mintPoints;
        amounts[1] = burnPoints;
        amounts[2] = mintPositionPoints;
        amounts[3] = burnPositionPoints;

        vm.prank(OWNER);
        facet.setPointsPerActionBatch(actions, amounts);
    }

    function _isIndexWeightAction(bytes32 actionType) internal pure returns (bool) {
        return actionType == LibPoints.ACTION_INDEX_MINT || actionType == LibPoints.ACTION_INDEX_BURN
            || actionType == LibPoints.ACTION_INDEX_MINT_POSITION || actionType == LibPoints.ACTION_INDEX_BURN_POSITION;
    }
}

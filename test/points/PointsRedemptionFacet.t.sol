// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PointsRedemptionFacet, Points_InvalidRedeemRecipient, Points_SlippageExceeded} from
    "../../src/points/PointsRedemptionFacet.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract PointsRedemptionHarness is PointsRedemptionFacet {
    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function accrue(address user, bytes32 actionType) external {
        LibPoints.accrue(user, actionType);
    }

    function pointsBalance(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function pointsBurned(address user) external view returns (uint256) {
        return LibPoints.burnedOf(user);
    }

    function redemptionTotalMinted() external view returns (uint256) {
        return LibPoints.redemptionTotalMinted();
    }

    function redemptionMintedInCurrentEpoch() external view returns (uint256) {
        return LibPoints.redemptionMintedInCurrentEpoch();
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
}

contract PointsRedemptionFacetTest is Test {
    bytes32 internal constant ACTION = keccak256("POINTS_REDEMPTION_TEST_ACTION");

    PointsRedemptionHarness internal facet;
    MockERC20 internal token;
    address internal constant USER = address(0xA11CE);

    function setUp() public {
        facet = new PointsRedemptionHarness();
        token = new MockERC20("Points Emission", "PEM", 18, 0);

        facet.setPointsPerAction(ACTION, 100);
        facet.accrue(USER, ACTION);
    }

    function _enableRedemption() internal {
        facet.setRedemptionToken(address(token));
        facet.setRedemptionRate(2e18); // 2 token out per point in
        facet.setRedemptionEnabled(true);
    }

    function test_redeem_revertsWhenDisabled() public {
        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_RedemptionDisabled.selector);
        facet.redeem(5, 0, USER);
    }

    function test_redeem_revertsWhenRecipientZero() public {
        _enableRedemption();
        vm.prank(USER);
        vm.expectRevert(Points_InvalidRedeemRecipient.selector);
        facet.redeem(5, 0, address(0));
    }

    function test_redeem_revertsWhenSlippageExceeded() public {
        _enableRedemption();
        vm.prank(USER);
        vm.expectRevert(Points_SlippageExceeded.selector);
        facet.redeem(5, 11, USER); // out=10
    }

    function test_redeem_success_burnsPointsAndMintsTokens() public {
        _enableRedemption();

        vm.prank(USER);
        uint256 out = facet.redeem(12, 24, USER);

        assertEq(out, 24);
        assertEq(token.balanceOf(USER), 24);
        assertEq(facet.pointsBalance(USER), 88);
        assertEq(facet.pointsBurned(USER), 12);
        assertEq(facet.redemptionTotalMinted(), 24);
    }

    function test_redeem_respectsGlobalMintCap() public {
        _enableRedemption();
        facet.setRedemptionGlobalMintCap(20);

        vm.prank(USER);
        facet.redeem(10, 20, USER);

        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_GlobalMintCapExceeded.selector);
        facet.redeem(1, 0, USER);
    }

    function test_redeem_respectsEpochMintCap() public {
        _enableRedemption();
        facet.setRedemptionEpochConfig(1 days, 20);

        vm.prank(USER);
        facet.redeem(9, 18, USER);
        assertEq(facet.redemptionMintedInCurrentEpoch(), 18);

        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_EpochMintCapExceeded.selector);
        facet.redeem(2, 0, USER);

        vm.warp(block.timestamp + 1 days);
        assertEq(facet.redemptionMintedInCurrentEpoch(), 0);

        vm.prank(USER);
        facet.redeem(2, 4, USER);
        assertEq(facet.redemptionMintedInCurrentEpoch(), 4);
    }
}

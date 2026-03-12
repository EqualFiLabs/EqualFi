// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PointsRedemptionFacet, Points_InvalidRedeemRecipient, Points_SlippageExceeded} from
    "../../src/points/PointsRedemptionFacet.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {IPointsEmissionToken} from "../../src/interfaces/IPointsEmissionToken.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";

contract MockPointsEmissionToken is IPointsEmissionToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalMinted;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalMinted += amount;
    }
}

contract PointsRedemptionV1Harness is PointsRedemptionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function accrue(address user, bytes32 actionType) external {
        LibPoints.accrue(user, actionType);
    }

    function accrueToKey(bytes32 pointsKey, bytes32 actionType) external {
        LibPoints.accrue(pointsKey, actionType);
    }

    function pointsBalance(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function pointsBalanceKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.balanceOf(pointsKey);
    }

    function pointsBurned(address user) external view returns (uint256) {
        return LibPoints.burnedOf(user);
    }

    function pointsBurnedKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.burnedOf(pointsKey);
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

contract PointsRedemptionFacetV1Test is Test {
    bytes32 internal constant ACTION = keccak256("POINTS_REDEMPTION_V1_ACTION");
    address internal constant USER = address(0xA11CE);
    address internal constant RECEIVER = address(0xB0B);

    PointsRedemptionV1Harness internal facet;
    MockPointsEmissionToken internal emission;
    PositionNFT internal nft;

    function setUp() public {
        facet = new PointsRedemptionV1Harness();
        emission = new MockPointsEmissionToken();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.configurePositionNFT(address(nft));

        facet.setPointsPerAction(ACTION, 100);
        facet.accrue(USER, ACTION);
    }

    function test_redeem_reverts_whenDisabledOrInvalidRecipient() public {
        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_RedemptionDisabled.selector);
        facet.redeem(5, 0, USER);

        _enableRedemption();
        vm.prank(USER);
        vm.expectRevert(Points_InvalidRedeemRecipient.selector);
        facet.redeem(5, 0, address(0));
    }

    function test_redeem_success_and_caps() public {
        _enableRedemption();

        vm.prank(USER);
        uint256 out = facet.redeem(12, 24, USER);
        assertEq(out, 24);
        assertEq(emission.balanceOf(USER), 24);
        assertEq(facet.pointsBalance(USER), 88);
        assertEq(facet.pointsBurned(USER), 12);
        assertEq(facet.redemptionTotalMinted(), 24);

        facet.setRedemptionGlobalMintCap(24);
        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_GlobalMintCapExceeded.selector);
        facet.redeem(1, 0, USER);
    }

    function test_redeem_respects_slippageAndEpochCap() public {
        _enableRedemption();
        facet.setRedemptionEpochConfig(1 days, 20);

        vm.prank(USER);
        vm.expectRevert(Points_SlippageExceeded.selector);
        facet.redeem(5, 11, USER);

        vm.prank(USER);
        facet.redeem(9, 18, USER);
        assertEq(facet.redemptionMintedInCurrentEpoch(), 18);

        vm.prank(USER);
        vm.expectRevert(LibPoints.Points_EpochMintCapExceeded.selector);
        facet.redeem(2, 0, USER);

        vm.warp(block.timestamp + 1 days);
        assertEq(facet.redemptionMintedInCurrentEpoch(), 0);
    }

    function test_redeemFromPosition_requiresOwner_and_redeemsPositionKey() public {
        _enableRedemption();

        uint256 positionId = nft.mint(USER, 1);
        bytes32 pointsKey = nft.getPositionKey(positionId);
        facet.accrueToKey(pointsKey, ACTION);

        vm.prank(RECEIVER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, RECEIVER, positionId));
        facet.redeemFromPosition(positionId, 10, 0, RECEIVER);

        vm.prank(USER);
        uint256 out = facet.redeemFromPosition(positionId, 40, 80, RECEIVER);
        assertEq(out, 80);
        assertEq(emission.balanceOf(RECEIVER), 80);
        assertEq(facet.pointsBalanceKey(pointsKey), 60);
        assertEq(facet.pointsBurnedKey(pointsKey), 40);
    }

    function test_redeemFromPosition_reverts_onRecipientAndSlippage() public {
        _enableRedemption();

        uint256 positionId = nft.mint(USER, 1);
        bytes32 pointsKey = nft.getPositionKey(positionId);
        facet.accrueToKey(pointsKey, ACTION);

        vm.prank(USER);
        vm.expectRevert(Points_InvalidRedeemRecipient.selector);
        facet.redeemFromPosition(positionId, 10, 0, address(0));

        vm.prank(USER);
        vm.expectRevert(Points_SlippageExceeded.selector);
        facet.redeemFromPosition(positionId, 10, 21, USER); // 10 * 2 = 20
    }

    function _enableRedemption() internal {
        facet.setRedemptionToken(address(emission));
        facet.setRedemptionRate(2e18);
        facet.setRedemptionEnabled(true);
    }
}

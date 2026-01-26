// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidAsset, DirectError_InvalidTimestamp, DirectError_ZeroAmount} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 12: Data integrity preservation (input validation)
/// @notice Validates: Requirements 1.4, 1.5
/// forge-config: default.fuzz.runs = 100
contract DirectInputValidationPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
    }

    function testProperty_InputValidationRevertsOnInvalidParams() public {
        vm.warp(1 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        finalizePositionNFT();
        harness.initPool(1, address(asset));
        harness.initPool(2, address(asset));

        DirectTypes.DirectOfferParams memory zeroPrincipal =
            _params(lenderPositionId, 1, 1, address(asset), address(asset), 0, 1 ether, 500, 2 days);
        vm.expectRevert(DirectError_ZeroAmount.selector);
        vm.prank(lenderOwner);
        offers.postOffer(zeroPrincipal);

        DirectTypes.DirectOfferParams memory zeroCollateral =
            _params(lenderPositionId, 1, 1, address(asset), address(asset), 1 ether, 0, 500, 2 days);
        vm.expectRevert(DirectError_ZeroAmount.selector);
        vm.prank(lenderOwner);
        offers.postOffer(zeroCollateral);

        DirectTypes.DirectOfferParams memory zeroDuration =
            _params(lenderPositionId, 1, 1, address(asset), address(asset), 1 ether, 1 ether, 500, 0);
        vm.expectRevert(DirectError_InvalidTimestamp.selector);
        vm.prank(lenderOwner);
        offers.postOffer(zeroDuration);

        DirectTypes.DirectOfferParams memory mismatchedAsset =
            _params(lenderPositionId, 1, 2, address(asset), address(0), 1 ether, 1 ether, 500, 2 days);
        vm.expectRevert(DirectError_InvalidAsset.selector);
        vm.prank(lenderOwner);
        offers.postOffer(mismatchedAsset);
    }

    function _params(
        uint256 lenderPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address collateralAsset,
        address borrowAsset,
        uint256 principal,
        uint256 collateralLockAmount,
        uint16 aprBps,
        uint64 durationSeconds
    ) internal pure returns (DirectTypes.DirectOfferParams memory) {
        return DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: lenderPoolId,
            collateralPoolId: collateralPoolId,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            principal: principal,
            aprBps: aprBps,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});
    }
}

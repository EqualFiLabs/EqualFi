// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";
import {InsufficientPrincipal} from "../../../src/libraries/Errors.sol";

contract DirectSolvencyGuardTest is DirectDiamondTestBase {
    bytes32 internal constant ENCUMBRANCE_STORAGE_POSITION = keccak256("equallend.encumbrance.storage");

    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);

        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 0,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 10_000,
                defaultLenderBps: 10_000,
                minInterestDuration: 0
            })
        );
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function test_postOffer_revertsWhenLenderWouldBreachSolvency() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 100 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), lenderKey, 0, 8_000, true);
        harness.setRollingDebt(1, lenderKey, 80 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 1 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        vm.expectRevert(bytes("SolvencyViolation: Lender LTV"));
        offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
    }

    function test_acceptOffer_revertsWhenBorrowerWouldBreachSolvency() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 3);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 4);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 200 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), borrowerKey, 100 ether, 8_000, true);
        harness.setRollingDebt(2, borrowerKey, 60 ether);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 50 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        vm.prank(borrowerOwner);
        vm.expectRevert(bytes("SolvencyViolation: Borrower LTV"));
        agreements.acceptOffer(offerId, borrowerPositionId, 0);
    }

    function test_postBorrowerOffer_revertsWhenModuleEncumbranceReducesAvailableCollateral() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 5);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 6);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 300 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), borrowerKey, 100 ether, 8_000, true);
        _setModuleEncumbered(borrowerKey, 2, 90 ether);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 20 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 20 ether, 10 ether));
        offers.postBorrowerOffer(params);
    }

    function test_postBorrowerRatioTrancheOffer_revertsWhenModuleEncumbranceReducesAvailableCollateral() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 7);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 8);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 300 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), borrowerKey, 100 ether, 8_000, true);
        _setModuleEncumbered(borrowerKey, 2, 90 ether);

        DirectTypes.DirectBorrowerRatioTrancheParams memory params = DirectTypes.DirectBorrowerRatioTrancheParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            collateralCap: 20 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 20 ether, 10 ether));
        offers.postBorrowerRatioTrancheOffer(params);
    }

    function test_acceptOffer_revertsWhenBorrowerModuleEncumbranceReducesAvailableCollateral() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 9);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 10);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 300 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), borrowerKey, 100 ether, 8_000, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        _setModuleEncumbered(borrowerKey, 2, 90 ether);

        vm.prank(borrowerOwner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 20 ether, 10 ether));
        agreements.acceptOffer(offerId, borrowerPositionId, 0);
    }

    function test_acceptRatioTrancheOffer_revertsWhenBorrowerModuleEncumbranceReducesAvailableCollateral() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 11);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 12);
        _finalizeMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithLtv(1, address(asset), lenderKey, 300 ether, 8_000, true);
        harness.seedPoolWithLtv(2, address(asset), borrowerKey, 100 ether, 8_000, true);

        DirectTypes.DirectRatioTrancheParams memory params = DirectTypes.DirectRatioTrancheParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principalCap: 100 ether,
            priceNumerator: 1,
            priceDenominator: 1,
            minPrincipalPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postRatioTrancheOffer(params);

        _setModuleEncumbered(borrowerKey, 2, 90 ether);

        vm.prank(borrowerOwner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 20 ether, 10 ether));
        agreements.acceptRatioTrancheOffer(offerId, borrowerPositionId, 20 ether, 0);
    }

    function _setModuleEncumbered(bytes32 positionKey, uint256 pid, uint256 amount) internal {
        bytes32 positionSlot = keccak256(abi.encode(positionKey, ENCUMBRANCE_STORAGE_POSITION));
        bytes32 encumbranceSlot = keccak256(abi.encode(pid, positionSlot));
        bytes32 moduleSlot = bytes32(uint256(encumbranceSlot) + 4);
        vm.store(address(diamond), moduleSlot, bytes32(amount));
    }
}

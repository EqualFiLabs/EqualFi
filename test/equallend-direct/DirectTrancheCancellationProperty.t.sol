// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: tranche-backed-offers, Property 7/12 cancellation and access control
/// forge-config: default.fuzz.runs = 100
contract DirectTrancheCancellationPropertyTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;
    address internal protocolTreasury = address(0xFEE1);

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 1_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 1_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function _postTrancheOffer(
        address lenderOwner,
        uint256 lenderPrincipal,
        uint256 principal,
        uint256 trancheAmount
    ) internal returns (uint256 offerId, bytes32 lenderKey, uint256 lenderPos) {
        lenderPos = nft.mint(lenderOwner, LENDER_POOL);
        lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, lenderPrincipal, false);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, lenderPrincipal, false);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: trancheAmount});

        vm.prank(lenderOwner);
        offerId = offers.postOffer(params, tranche);
    }

    /// @notice Feature: tranche-backed-offers, Property 7: Tranche cancellation completeness
    /// @notice Validates: Requirements 3.1, 3.2, 3.3
    function testProperty_TrancheCancellationCompleteness(
        address lenderOwner,
        uint256 principal,
        uint256 trancheAmount
    ) public {
        vm.assume(lenderOwner != address(0));
        vm.assume(lenderOwner.code.length == 0);
        principal = bound(principal, 1 ether, 100_000 ether);
        trancheAmount = bound(trancheAmount, principal, 500_000 ether);
        uint256 lenderPrincipal = trancheAmount * 2;

        (uint256 offerId, bytes32 lenderKey,) = _postTrancheOffer(lenderOwner, lenderPrincipal, principal, trancheAmount);
        _finalizeMinter();
        uint256 escrowBefore = views.offerEscrow(lenderKey, LENDER_POOL);

        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);

        assertEq(views.trancheRemaining(offerId), 0, "tranche zeroed on cancel");
        uint256 escrowAfter = views.offerEscrow(lenderKey, LENDER_POOL);
        assertEq(escrowBefore - escrowAfter, trancheAmount, "escrow released tranche");
    }

    /// @notice Feature: tranche-backed-offers, Property 12: Access control enforcement
    /// @notice Validates: Requirements 7.4
    function testProperty_CancelAccessControl(address lenderOwner, address attacker) public {
        vm.assume(lenderOwner != address(0));
        vm.assume(attacker != address(0));
        vm.assume(lenderOwner != attacker);
        vm.assume(attacker.code.length == 0);
        vm.assume(lenderOwner.code.length == 0);

        uint256 principal = 10 ether;
        uint256 trancheAmount = 20 ether;
        (, , uint256 lenderPos) = _postTrancheOffer(lenderOwner, 40 ether, principal, trancheAmount);
        _finalizeMinter();

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, lenderPos));
        vm.prank(attacker);
        offers.cancelOffer(1);
    }
}

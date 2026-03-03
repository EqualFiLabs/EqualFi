// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPerpsIdentity} from "../../src/perps/LibPerpsIdentity.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {
    Perps_Unauthorized,
    Perps_RiskLimitExceeded,
    Perps_InsufficientPerpsLiquidity,
    Perps_DecreasePaused
} from "../../src/perps/PerpsErrors.sol";

contract PerpsExecutionHarness is PerpsExecutionFacet {
    function setPositionNft(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function seedMarket(bytes32 marketId, uint256 collateralPoolId, address collateralAsset, bool pauseDecrease) external {
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = collateralPoolId;
        market.collateralAsset = collateralAsset;
        market.indexAsset = address(0xB0B);
        market.longEnabled = true;
        market.shortEnabled = true;
        market.pauseDecrease = pauseDecrease;
        market.exists = true;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function accountCount() external view returns (uint256) {
        return LibPerpsStorage.s().accountCount;
    }

    function domainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function marketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function poolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }
}

contract PerpsExecutionFacetTest is Test {
    PerpsExecutionHarness internal h;
    PositionNFT internal nft;

    address internal owner = address(0xA11CE);
    address internal operator = address(0xCAFE);
    address internal other = address(0xDEAD);

    uint256 internal tokenId;
    bytes32 internal marketId = keccak256("perps.market.exec");
    uint256 internal collateralPoolId = 77;
    address internal collateralAsset = address(0xC011A7);

    function setUp() public {
        h = new PerpsExecutionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(owner, collateralPoolId);

        h.setPositionNft(address(nft), true);
        h.seedMarket(marketId, collateralPoolId, collateralAsset, false);
        h.setPoolTrackedBalance(collateralPoolId, 1_000_000e6);
    }

    function test_createAccount_derivationAndViews_roundTrip() public {
        bytes32 positionKey = nft.getPositionKey(tokenId);
        bytes32 expectedAccountId = LibPerpsIdentity.deriveAccountId(positionKey, 0);

        vm.prank(owner);
        bytes32 accountId = h.createAccount(tokenId, 0);
        assertEq(accountId, expectedAccountId);
        assertEq(h.accountCount(), 1);
        assertTrue(h.accountExists(accountId));

        LibPerpsStorage.PerpsAccount memory account = h.getAccount(accountId);
        assertEq(account.accountId, expectedAccountId);
        assertEq(account.positionKey, positionKey);
        assertEq(account.positionTokenId, tokenId);
        assertEq(account.nonce, 0);
        assertTrue(account.exists);

        bytes32 derivedView = h.deriveAccountIdForPosition(tokenId, 0);
        assertEq(derivedView, expectedAccountId);

        vm.prank(owner);
        bytes32 secondCall = h.createAccount(tokenId, 0);
        assertEq(secondCall, expectedAccountId);
        assertEq(h.accountCount(), 1);
    }

    function test_createAccount_authorityFollowsNftApprovalRules() public {
        vm.prank(owner);
        nft.approve(operator, tokenId);

        vm.prank(operator);
        bytes32 accountId = h.createAccount(tokenId, 1);
        assertTrue(h.accountExists(accountId));

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Perps_Unauthorized.selector, bytes32(0), other));
        h.createAccount(tokenId, 2);
    }

    function test_addRemoveCollateral_updatesPerpsDomainOnlyAndPreservesPoolTracked() public {
        vm.prank(owner);
        bytes32 accountId = h.createAccount(tokenId, 0);

        uint256 trackedBefore = h.poolTrackedBalance(collateralPoolId);

        vm.prank(owner);
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 2_000e6
            })
        );

        assertEq(h.getAccountCollateral(marketId, accountId), 2_000e6);
        assertEq(h.marketState(marketId).reservedCollateral, 2_000e6);
        LibPerpsStorage.PerpsDomainState memory dsAfterAdd = h.domainState();
        assertEq(dsAfterAdd.isolatedTrackedBalance, 2_000e6);
        assertEq(dsAfterAdd.isolatedEncumbered, 2_000e6);
        assertEq(h.poolTrackedBalance(collateralPoolId), trackedBefore);

        vm.prank(owner);
        h.removeCollateral(
            PerpsExecutionFacet.RemoveCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 500e6
            })
        );

        assertEq(h.getAccountCollateral(marketId, accountId), 1_500e6);
        assertEq(h.marketState(marketId).reservedCollateral, 1_500e6);
        LibPerpsStorage.PerpsDomainState memory dsAfterRemove = h.domainState();
        assertEq(dsAfterRemove.isolatedTrackedBalance, 1_500e6);
        assertEq(dsAfterRemove.isolatedEncumbered, 1_500e6);
        assertEq(h.poolTrackedBalance(collateralPoolId), trackedBefore);
    }

    function test_removeCollateral_rejectsOverwithdrawAndPauseAndWrongAsset() public {
        vm.prank(owner);
        bytes32 accountId = h.createAccount(tokenId, 0);

        vm.prank(owner);
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 1_000e6
            })
        );

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Perps_InsufficientPerpsLiquidity.selector, 2_000e6, 1_000e6));
        h.removeCollateral(
            PerpsExecutionFacet.RemoveCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 2_000e6
            })
        );

        vm.prank(owner);
        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: address(0xBAD),
                amount: 1
            })
        );

        h.seedMarket(marketId, collateralPoolId, collateralAsset, true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Perps_DecreasePaused.selector, marketId));
        h.removeCollateral(
            PerpsExecutionFacet.RemoveCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 1
            })
        );
    }

    function test_accountAuthority_followsCurrentNftOwnerAfterTransfer() public {
        vm.prank(owner);
        bytes32 accountId = h.createAccount(tokenId, 0);

        vm.prank(owner);
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 500e6
            })
        );

        vm.prank(owner);
        nft.transferFrom(owner, other, tokenId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Perps_Unauthorized.selector, accountId, owner));
        h.removeCollateral(
            PerpsExecutionFacet.RemoveCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 100e6
            })
        );

        vm.prank(other);
        h.removeCollateral(
            PerpsExecutionFacet.RemoveCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: 100e6
            })
        );
        assertEq(h.getAccountCollateral(marketId, accountId), 400e6);
    }
}

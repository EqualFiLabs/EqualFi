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
    Perps_DecreasePaused,
    Perps_InsufficientPerpsLiquidity,
    Perps_NonceMismatch,
    Perps_PriceOutOfBounds,
    Perps_PriceStale,
    Perps_RiskLimitExceeded,
    Perps_Unauthorized
} from "../../src/perps/PerpsErrors.sol";

contract PerpsExecutionHarness is PerpsExecutionFacet {
    uint256 internal oraclePriceX18 = 2_000e18;
    uint256 internal oracleUpdatedAt = block.timestamp;
    uint256 internal oracleDeviationBps;

    function setOracleData(uint256 priceX18, uint256 updatedAt, uint256 deviationBps) external {
        oraclePriceX18 = priceX18;
        oracleUpdatedAt = updatedAt;
        oracleDeviationBps = deviationBps;
    }

    function getMarkPrice(bytes32, address) external view returns (uint256 priceX18, uint256 updatedAt, uint256 deviationBps) {
        return (oraclePriceX18, oracleUpdatedAt, oracleDeviationBps);
    }

    function setOracleConfig(bytes32 marketId, uint256 maxStaleness, uint256 maxDeviationBps) external {
        if (maxStaleness > type(uint32).max || maxDeviationBps > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.maxStaleness = uint32(maxStaleness);
        market.maxDeviationBps = uint32(maxDeviationBps);
    }

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
        market.maxLeverageBps = 50_000;
        market.initialMarginBps = 1_000;
        market.maintenanceMarginBps = 700;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = 1_000_000e18;
        market.takerFeeBps = 100;
        market.maxFundingVelocityBpsPerDay = 1_000;
        market.oracleAdapter = address(this);
        market.maxStaleness = type(uint32).max;
        market.maxDeviationBps = 2_000;
        market.pauseIncrease = false;
        market.pauseDecrease = pauseDecrease;
        market.pauseLiquidation = false;
        market.pauseSync = false;
        market.exists = true;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function seedFeePool(uint256 poolId, address underlying, uint256 totalDeposits, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].underlying = underlying;
        LibAppStorage.s().pools[poolId].totalDeposits = totalDeposits;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function configureFeeRouter(uint256 treasuryBps, uint256 activeCreditBps, address treasury) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert Perps_RiskLimitExceeded();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareConfigured = true;
        store.treasuryShareBps = uint16(treasuryBps);
        store.activeCreditShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
    }

    function accountCount() external view returns (uint256) {
        return LibPerpsStorage.s().accountCount;
    }

    function accountNonce(bytes32 accountId) external view returns (uint64) {
        return LibPerpsStorage.s().accounts[accountId].nonce;
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

    function poolFeeIndex(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].feeIndex;
    }

    function poolYieldReserve(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].yieldReserve;
    }
}

contract PerpsExecutionFacetTest is Test {
    PerpsExecutionHarness internal h;
    PositionNFT internal nft;

    uint256 internal ownerKey;
    address internal owner;
    address internal operator = address(0xCAFE);
    address internal executor = address(0xEEEE);
    address internal other = address(0xDEAD);

    uint256 internal tokenId;
    bytes32 internal marketId = keccak256("perps.market.exec");
    uint256 internal collateralPoolId = 77;
    address internal collateralAsset = address(0xC011A7);

    function setUp() public {
        ownerKey = 0xA11CE;
        owner = vm.addr(ownerKey);

        h = new PerpsExecutionHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(owner, collateralPoolId);

        h.setPositionNft(address(nft), true);
        h.seedMarket(marketId, collateralPoolId, collateralAsset, false);
        h.seedFeePool(collateralPoolId, collateralAsset, 1_000e18, 2_000_000e18);
        h.configureFeeRouter(0, 0, address(0));
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

    function test_openOrIncrease_revertsOnOracleStaleInvalidAndOutOfBounds() public {
        bytes32 accountId = _createAndFundAccount(20_000e18);
        PerpsExecutionFacet.OpenIncreaseParams memory params = PerpsExecutionFacet.OpenIncreaseParams({
            marketId: marketId,
            accountId: accountId,
            isLong: true,
            sizeDeltaUsdX18: 5_000e18,
            executionPriceX18: 2_000e18,
            limitPriceX18: 2_000e18,
            maxSlippageBps: 100,
            feePoolId: collateralPoolId,
            executorFee: 0
        });

        vm.warp(100);
        h.setOracleConfig(marketId, 1, 2_000);
        h.setOracleData(2_000e18, 98, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Perps_PriceStale.selector, 98, uint32(1)));
        h.openOrIncrease(params);

        h.setOracleConfig(marketId, 1 days, 2_000);
        h.setOracleData(0, block.timestamp, 0);
        vm.prank(owner);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.openOrIncrease(params);

        h.setOracleConfig(marketId, 1 days, 500);
        h.setOracleData(2_000e18, block.timestamp, 0);
        params.executionPriceX18 = 2_300e18;
        params.limitPriceX18 = 2_300e18;
        vm.prank(owner);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.openOrIncrease(params);

        h.setOracleData(2_300e18, block.timestamp, 700);
        vm.prank(owner);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.openOrIncrease(params);
    }

    function test_decreaseOrClose_revertsOnOracleStale() public {
        bytes32 accountId = _createAndFundAccount(20_000e18);

        vm.prank(owner);
        h.openOrIncrease(
            PerpsExecutionFacet.OpenIncreaseParams({
                marketId: marketId,
                accountId: accountId,
                isLong: true,
                sizeDeltaUsdX18: 5_000e18,
                executionPriceX18: 2_000e18,
                limitPriceX18: 2_000e18,
                maxSlippageBps: 100,
                feePoolId: collateralPoolId,
                executorFee: 0
            })
        );

        vm.warp(200);
        h.setOracleConfig(marketId, 1, 2_000);
        h.setOracleData(2_100e18, 198, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Perps_PriceStale.selector, 198, uint32(1)));
        h.decreaseOrClose(
            PerpsExecutionFacet.DecreaseCloseParams({
                marketId: marketId,
                accountId: accountId,
                isLong: true,
                sizeDeltaUsdX18: 1_000e18,
                executionPriceX18: 2_100e18,
                limitPriceX18: 2_100e18,
                maxSlippageBps: 100,
                feePoolId: collateralPoolId,
                executorFee: 0
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

    function test_openIncreaseAndDecreaseClose_directPath_updatesStateAndSettlementDeltas() public {
        bytes32 accountId = _createAndFundAccount(20_000e18);

        uint256 feeIndexBefore = h.poolFeeIndex(collateralPoolId);
        PerpsExecutionFacet.OpenIncreaseParams memory openParams = PerpsExecutionFacet.OpenIncreaseParams({
            marketId: marketId,
            accountId: accountId,
            isLong: true,
            sizeDeltaUsdX18: 10_000e18,
            executionPriceX18: 2_000e18,
            limitPriceX18: 2_000e18,
            maxSlippageBps: 100,
            feePoolId: collateralPoolId,
            executorFee: 10e18
        });

        vm.prank(owner);
        LibPerpsStorage.SettlementDelta memory openDelta = h.openOrIncrease(openParams);
        assertEq(openDelta.takerFee, 100e18);
        assertEq(openDelta.lpFee, 70e18);
        assertEq(openDelta.protocolFee, 30e18);
        assertEq(openDelta.executorFee, 10e18);

        LibPerpsStorage.PerpsPosition memory position = h.getPosition(marketId, accountId, true);
        assertEq(position.sizeUsdX18, 10_000e18);
        assertEq(position.entryPriceX18, 2_000e18);

        LibPerpsStorage.PerpsMarketState memory stateAfterOpen = h.marketState(marketId);
        assertEq(stateAfterOpen.openInterestLong, 10_000e18);
        assertEq(stateAfterOpen.openInterestShort, 0);
        assertEq(stateAfterOpen.lpFeeIndexX18, 70e18);
        assertEq(stateAfterOpen.protocolFeesAccrued, 30e18);

        // Domain debits only protocol + executor fee on open
        assertEq(h.domainState().isolatedTrackedBalance, 19_960e18);
        assertGt(h.poolFeeIndex(collateralPoolId), feeIndexBefore);

        PerpsExecutionFacet.DecreaseCloseParams memory decParams = PerpsExecutionFacet.DecreaseCloseParams({
            marketId: marketId,
            accountId: accountId,
            isLong: true,
            sizeDeltaUsdX18: 5_000e18,
            executionPriceX18: 2_200e18,
            limitPriceX18: 2_200e18,
            maxSlippageBps: 100,
            feePoolId: collateralPoolId,
            executorFee: 5e18
        });

        vm.prank(owner);
        LibPerpsStorage.SettlementDelta memory decDelta = h.decreaseOrClose(decParams);
        assertEq(decDelta.realizedPnl, 500e18);
        assertEq(decDelta.takerFee, 50e18);
        assertEq(decDelta.executorFee, 5e18);
        assertEq(decDelta.collateralInOut, 445e18);

        LibPerpsStorage.PerpsPosition memory positionAfterDec = h.getPosition(marketId, accountId, true);
        assertEq(positionAfterDec.sizeUsdX18, 5_000e18);

        PerpsExecutionFacet.DecreaseCloseParams memory closeParams = PerpsExecutionFacet.DecreaseCloseParams({
            marketId: marketId,
            accountId: accountId,
            isLong: true,
            sizeDeltaUsdX18: 5_000e18,
            executionPriceX18: 1_800e18,
            limitPriceX18: 1_800e18,
            maxSlippageBps: 100,
            feePoolId: collateralPoolId,
            executorFee: 5e18
        });

        vm.prank(owner);
        LibPerpsStorage.SettlementDelta memory closeDelta = h.decreaseOrClose(closeParams);
        assertEq(closeDelta.realizedPnl, -500e18);

        LibPerpsStorage.PerpsPosition memory closed = h.getPosition(marketId, accountId, true);
        assertEq(closed.sizeUsdX18, 0);
    }

    function test_executeIntent_openAndClose_sharedCoreAndNonceProgression() public {
        bytes32 accountId = _createAndFundAccount(20_000e18);

        LibPerpsStorage.PerpsIntent memory openIntent = LibPerpsStorage.PerpsIntent({
            marketId: marketId,
            accountId: accountId,
            action: 1,
            isLong: true,
            sizeDeltaUsdX18: 6_000e18,
            collateralDelta: 0,
            limitPriceX18: 2_000e18,
            maxSlippageBps: 100,
            maxExecutorFee: 20e18,
            nonce: 0,
            deadline: uint64(block.timestamp + 1 days)
        });

        bytes memory openSig = _signIntent(openIntent);
        vm.prank(executor);
        LibPerpsStorage.SettlementDelta memory openDelta = h.executeIntent(
            openIntent,
            PerpsExecutionFacet.IntentExecutionParams({
                signer: owner,
                executionPriceX18: 2_000e18,
                feePoolId: collateralPoolId,
                executorFee: 10e18
            }),
            openSig
        );

        assertEq(openDelta.takerFee, 60e18);
        assertEq(h.accountNonce(accountId), 1);
        assertEq(h.getPosition(marketId, accountId, true).sizeUsdX18, 6_000e18);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Perps_NonceMismatch.selector, uint64(1), uint64(0)));
        h.executeIntent(
            openIntent,
            PerpsExecutionFacet.IntentExecutionParams({
                signer: owner,
                executionPriceX18: 2_000e18,
                feePoolId: collateralPoolId,
                executorFee: 10e18
            }),
            openSig
        );

        LibPerpsStorage.PerpsIntent memory closeIntent = LibPerpsStorage.PerpsIntent({
            marketId: marketId,
            accountId: accountId,
            action: 2,
            isLong: true,
            sizeDeltaUsdX18: 6_000e18,
            collateralDelta: 0,
            limitPriceX18: 2_100e18,
            maxSlippageBps: 100,
            maxExecutorFee: 20e18,
            nonce: 1,
            deadline: uint64(block.timestamp + 1 days)
        });

        bytes memory closeSig = _signIntent(closeIntent);
        vm.prank(executor);
        LibPerpsStorage.SettlementDelta memory closeDelta = h.executeIntent(
            closeIntent,
            PerpsExecutionFacet.IntentExecutionParams({
                signer: owner,
                executionPriceX18: 2_100e18,
                feePoolId: collateralPoolId,
                executorFee: 10e18
            }),
            closeSig
        );

        assertEq(closeDelta.realizedPnl, 300e18);
        assertEq(h.accountNonce(accountId), 2);
        assertEq(h.getPosition(marketId, accountId, true).sizeUsdX18, 0);
    }

    function _createAndFundAccount(uint256 collateralAmount) internal returns (bytes32 accountId) {
        vm.prank(owner);
        accountId = h.createAccount(tokenId, 0);

        vm.prank(owner);
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: marketId,
                accountId: accountId,
                collateralAsset: collateralAsset,
                amount: collateralAmount
            })
        );
    }

    function _signIntent(LibPerpsStorage.PerpsIntent memory intent) internal view returns (bytes memory signature) {
        bytes32 digest = h.intentDigest(intent);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}

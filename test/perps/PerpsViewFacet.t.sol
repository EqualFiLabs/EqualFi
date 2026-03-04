// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPerpsRisk} from "../../src/perps/LibPerpsRisk.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {PerpsViewFacet} from "../../src/perps/PerpsViewFacet.sol";
import {
    Perps_AccountNotFound,
    Perps_MarketNotFound,
    Perps_PriceOutOfBounds,
    Perps_PriceStale,
    Perps_RiskLimitExceeded
} from "../../src/perps/PerpsErrors.sol";

contract PerpsViewHarness is PerpsViewFacet {
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

    function setPositionNft(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function seedMarket(bytes32 marketId, uint256 collateralPoolId, address collateralAsset, bool pauseDecrease) external {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        bool isNew = !ps.markets[marketId].exists;
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
        ps.globalExecutionEnabled = true;
        ps.marketConfigMask[marketId] = 0x3f;

        if (isNew) {
            uint256 nextCount = ps.marketCount + 1;
            ps.marketCount = nextCount;
            ps.marketIds[nextCount] = marketId;
        }
    }

    function setOracleConfig(bytes32 marketId, uint256 maxStaleness, uint256 maxDeviationBps) external {
        if (maxStaleness > type(uint32).max || maxDeviationBps > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.maxStaleness = uint32(maxStaleness);
        market.maxDeviationBps = uint32(maxDeviationBps);
    }

    function seedMarketState(
        bytes32 marketId,
        uint256 insuranceBalance,
        uint256 insuranceTarget,
        uint256 badDebt,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18
    ) external {
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.insuranceBalance = insuranceBalance;
        state.insuranceTarget = insuranceTarget;
        state.badDebt = badDebt;
        state.cumulativeFundingLongX18 = cumulativeFundingLongX18;
        state.cumulativeFundingShortX18 = cumulativeFundingShortX18;
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered) external {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
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

    function delegateTo(address impl, bytes calldata callData) external returns (bytes memory result) {
        (bool ok, bytes memory ret) = impl.delegatecall(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        result = ret;
    }
}

contract PerpsViewFacetTest is Test {
    bytes32 internal constant MARKET_A = keccak256("perps.market.view.a");
    bytes32 internal constant MARKET_B = keccak256("perps.market.view.b");
    uint256 internal constant COLLATERAL_POOL_ID = 77;
    address internal constant COLLATERAL_ASSET = address(0xC011A7);

    PerpsViewHarness internal h;
    PerpsExecutionFacet internal execImpl;
    PositionNFT internal nft;

    uint256 internal ownerKey;
    address internal owner;
    uint256 internal tokenId;
    bytes32 internal accountId;

    function setUp() public {
        ownerKey = 0xA11CE;
        owner = vm.addr(ownerKey);

        h = new PerpsViewHarness();
        execImpl = new PerpsExecutionFacet();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(owner, COLLATERAL_POOL_ID);

        h.setPositionNft(address(nft), true);
        h.seedMarket(MARKET_A, COLLATERAL_POOL_ID, COLLATERAL_ASSET, false);
        h.seedMarket(MARKET_B, COLLATERAL_POOL_ID + 1, COLLATERAL_ASSET, false);
        h.seedFeePool(COLLATERAL_POOL_ID, COLLATERAL_ASSET, 1_000e18, 2_000_000e18);
        h.configureFeeRouter(0, 0, address(0));
        h.seedMarketState(MARKET_A, 25e18, 100e18, 0, 0, 0);
        h.setDomainState(2_000_000e18, 0, 0);

        accountId = _createAndOpenPosition();
    }

    function test_views_matchStateAfterExecutionTransition() public {
        LibPerpsStorage.PerpsMarket memory market = h.getMarket(MARKET_A);
        assertEq(market.marketId, MARKET_A);
        assertEq(market.collateralPoolId, COLLATERAL_POOL_ID);

        LibPerpsStorage.PerpsAccount memory account = h.getPerpsAccount(accountId);
        assertEq(account.positionTokenId, tokenId);
        assertTrue(account.exists);

        LibPerpsStorage.PerpsPosition memory position = h.getPerpsPosition(MARKET_A, accountId, true);
        assertEq(position.sizeUsdX18, 10_000e18);
        assertEq(position.entryPriceX18, 2_000e18);

        assertEq(h.getPerpsAccountCollateral(MARKET_A, accountId), 19_900e18);

        LibPerpsStorage.PerpsMarketState memory state = h.getMarketState(MARKET_A);
        assertEq(state.openInterestLong, 10_000e18);
        assertEq(state.openInterestShort, 0);
        assertEq(state.lpFeeIndexX18, 3_500_000_000_000_000);
        assertEq(state.protocolFeesAccrued, 30e18);

        PerpsViewFacet.SettlementSummary memory summary = h.getSettlementSummary(MARKET_A);
        assertEq(summary.openInterestLong, state.openInterestLong);
        assertEq(summary.lpFeeIndexX18, state.lpFeeIndexX18);
        assertEq(summary.protocolFeesAccrued, state.protocolFeesAccrued);
        assertEq(summary.isolatedTrackedBalance, h.proveIsolationInvariant(MARKET_A).isolatedTrackedBalance);

        PerpsViewFacet.FeeRoutingAudit memory audit = h.getFeeRoutingAudit(MARKET_A);
        assertEq(audit.lpFeeIndexX18, 3_500_000_000_000_000);
        assertEq(audit.lpFeePendingDistribution, 0);
        assertEq(audit.protocolFeesAccrued, 30e18);
        assertEq(audit.outboundRouterCredits, 30e18);
        assertEq(audit.insuranceTargetGap, 75e18);
        assertEq(audit.insuranceTargetProgressBps, 2_500);
        assertEq(audit.feePoolTrackedBalance, 2_000_030e18);
    }

    function test_previewHealthAndPreviewDelta_areConsistentAndSideEffectFree() public {
        h.setOracleData(2_100e18, block.timestamp, 0);

        LibPerpsStorage.PerpsMarketState memory beforeState = h.getMarketState(MARKET_A);

        (
            LibPerpsRisk.HealthResult memory health,
            LibPerpsRisk.HealthState memory baseState,
            uint256 markPriceX18
        ) = h.previewHealth(MARKET_A, accountId);
        assertEq(markPriceX18, 2_100e18);
        assertEq(baseState.positionNotionalUsdX18, 10_000e18);
        assertEq(baseState.unrealizedPnlUsdX18, int256(500e18));
        assertEq(health.equityUsdX18, int256(20_400e18));

        PerpsViewFacet.PreviewParams memory params = PerpsViewFacet.PreviewParams({
            marketId: MARKET_A,
            accountId: accountId,
            collateralDeltaUsdX18: -int256(100e18),
            positionNotionalDeltaUsdX18: -int256(2_000e18),
            unrealizedPnlDeltaUsdX18: 0,
            fundingAccruedDeltaUsdX18: 0,
            feeDeltaUsdX18: 50e18,
            executionPriceX18: 2_100e18
        });

        PerpsViewFacet.PreviewResult memory preview = h.previewDelta(params);
        (LibPerpsRisk.HealthResult memory expectedPost, LibPerpsRisk.HealthState memory expectedPostState) = LibPerpsRisk.previewHealth(
            h.getMarket(MARKET_A),
            baseState,
            LibPerpsRisk.HealthDelta({
                collateralDeltaUsdX18: params.collateralDeltaUsdX18,
                positionNotionalDeltaUsdX18: params.positionNotionalDeltaUsdX18,
                unrealizedPnlDeltaUsdX18: params.unrealizedPnlDeltaUsdX18,
                fundingAccruedDeltaUsdX18: params.fundingAccruedDeltaUsdX18,
                feeDeltaUsdX18: params.feeDeltaUsdX18
            })
        );

        assertEq(keccak256(abi.encode(preview.postState)), keccak256(abi.encode(expectedPostState)));
        assertEq(keccak256(abi.encode(preview.postHealth)), keccak256(abi.encode(expectedPost)));
        assertEq(
            keccak256(abi.encode(h.getMarketState(MARKET_A))),
            keccak256(abi.encode(beforeState)),
            "view preview must not mutate storage"
        );
    }

    function test_isolationProof_outputsGlobalAndMarketSolvency() public {
        h.seedMarketState(MARKET_A, 50e18, 100e18, 10e18, 0, 0);
        h.seedMarketState(MARKET_B, 20e18, 80e18, 30e18, 0, 0);
        h.setDomainState(1_000e18, 900e18, 100e18);

        PerpsViewFacet.IsolationProof memory proof = h.proveIsolationInvariant(MARKET_A);
        assertEq(proof.marketInsuranceBalance, 50e18);
        assertEq(proof.marketBadDebt, 10e18);
        assertEq(proof.totalInsuranceBalance, 70e18);
        assertEq(proof.totalBadDebt, 40e18);
        assertTrue(proof.marketSolvent);
        assertTrue(proof.globalSolvent);

        h.setDomainState(1_000e18, 1_200e18, 100e18);
        proof = h.proveIsolationInvariant(MARKET_A);
        assertFalse(proof.marketSolvent);
        assertFalse(proof.globalSolvent);
    }

    function test_viewReverts_unknownAccountOrMarket() public {
        bytes32 unknownMarket = keccak256("perps.market.unknown");
        bytes32 unknownAccount = keccak256("perps.account.unknown");

        vm.expectRevert(abi.encodeWithSelector(Perps_MarketNotFound.selector, unknownMarket));
        h.getMarket(unknownMarket);

        vm.expectRevert(abi.encodeWithSelector(Perps_AccountNotFound.selector, unknownAccount));
        h.getPerpsAccount(unknownAccount);
    }

    function test_previewHealthAndPreviewDelta_revertOnStaleInvalidAndOutOfBoundsOracle() public {
        vm.warp(100);
        h.setOracleConfig(MARKET_A, 1, 500);
        h.setOracleData(2_000e18, 98, 0);
        vm.expectRevert(abi.encodeWithSelector(Perps_PriceStale.selector, 98, uint32(1)));
        h.previewHealth(MARKET_A, accountId);

        h.setOracleConfig(MARKET_A, 1 days, 500);
        h.setOracleData(0, block.timestamp, 0);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.previewHealth(MARKET_A, accountId);

        h.setOracleData(2_000e18, block.timestamp, 0);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.previewDelta(
            PerpsViewFacet.PreviewParams({
                marketId: MARKET_A,
                accountId: accountId,
                collateralDeltaUsdX18: 0,
                positionNotionalDeltaUsdX18: 0,
                unrealizedPnlDeltaUsdX18: 0,
                fundingAccruedDeltaUsdX18: 0,
                feeDeltaUsdX18: 0,
                executionPriceX18: 2_300e18
            })
        );

        h.setOracleData(2_300e18, block.timestamp, 700);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.previewHealth(MARKET_A, accountId);
    }

    function _createAndOpenPosition() internal returns (bytes32 createdAccountId) {
        vm.prank(owner);
        bytes memory accountRet = h.delegateTo(address(execImpl), abi.encodeCall(PerpsExecutionFacet.createAccount, (tokenId, 0)));
        createdAccountId = abi.decode(accountRet, (bytes32));

        vm.prank(owner);
        h.delegateTo(
            address(execImpl),
            abi.encodeCall(
                PerpsExecutionFacet.addCollateral,
                (
                    PerpsExecutionFacet.AddCollateralParams({
                        marketId: MARKET_A,
                        accountId: createdAccountId,
                        collateralAsset: COLLATERAL_ASSET,
                        amount: 20_000e18
                    })
                )
            )
        );

        vm.prank(owner);
        h.delegateTo(
            address(execImpl),
            abi.encodeCall(
                PerpsExecutionFacet.openOrIncrease,
                (
                    PerpsExecutionFacet.OpenIncreaseParams({
                        marketId: MARKET_A,
                        accountId: createdAccountId,
                        isLong: true,
                        sizeDeltaUsdX18: 10_000e18,
                        executionPriceX18: 2_000e18,
                        limitPriceX18: 2_000e18,
                        maxSlippageBps: 100,
                        feePoolId: COLLATERAL_POOL_ID,
                        executorFee: 0
                    })
                )
            )
        );
    }
}

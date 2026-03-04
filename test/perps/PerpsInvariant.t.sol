// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {PerpsLiquidationFacet} from "../../src/perps/PerpsLiquidationFacet.sol";
import {Perps_RiskLimitExceeded} from "../../src/perps/PerpsErrors.sol";

contract PerpsInvariantHarness {
    uint256 internal oraclePriceX18 = 2_000e18;
    uint256 internal oracleUpdatedAt = block.timestamp;
    uint256 internal oracleDeviationBps;

    receive() external payable {}

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

    function seedMarket(
        bytes32 marketId,
        uint256 collateralPoolId,
        address collateralAsset,
        bool pauseDecrease,
        bool pauseSync,
        bool pauseLiquidation
    ) external {
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
        market.liquidationIncentiveBpsMax = 500;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = 1_000_000e18;
        market.takerFeeBps = 100;
        market.maxFundingVelocityBpsPerDay = 1_000;
        market.oracleAdapter = address(this);
        market.maxStaleness = type(uint32).max;
        market.maxDeviationBps = 2_000;
        market.pauseDecrease = pauseDecrease;
        market.pauseSync = pauseSync;
        market.pauseLiquidation = pauseLiquidation;
        market.exists = true;

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        ps.globalExecutionEnabled = true;
        ps.marketConfigMask[marketId] = 0x3f;
    }

    function seedMarketState(bytes32 marketId, uint256 insuranceBalance, uint256 insuranceTarget, uint256 badDebt) external {
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.insuranceBalance = insuranceBalance;
        state.insuranceTarget = insuranceTarget;
        state.badDebt = badDebt;
    }

    function setGlobalLiquidationEnabled(bool enabled) external {
        LibPerpsStorage.s().globalLiquidationEnabled = enabled;
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
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) {
            revert Perps_RiskLimitExceeded();
        }

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
        return ret;
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function getAccount(bytes32 accountId) external view returns (LibPerpsStorage.PerpsAccount memory) {
        return LibPerpsStorage.s().accounts[accountId];
    }

    function getAccountCollateral(bytes32 accountId, bytes32 marketId) external view returns (uint256) {
        return LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function getPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory)
    {
        return LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }
}

contract PerpsInvariantHandler is Test {
    bytes32 internal constant MARKET_A = keccak256("perps.market.invariant.a");
    bytes32 internal constant MARKET_B = keccak256("perps.market.invariant.b");
    uint256 internal constant POOL_ID = 909;
    address internal constant COLLATERAL_ASSET = address(0xC011A7);
    uint8 internal constant ACTION_OPEN = 1;
    uint8 internal constant ACTION_CLOSE = 2;

    PerpsInvariantHarness internal h;
    PerpsExecutionFacet internal execImpl;
    PerpsLiquidationFacet internal liqImpl;

    uint256 internal ownerKey = 0xA11CE;
    address internal owner;
    address internal executorA = address(0xA001);
    address internal executorB = address(0xB002);
    address internal keeperA = address(0xC003);
    address internal keeperB = address(0xD004);

    bytes32 internal accountId;
    uint256 internal oraclePriceX18;

    uint256 public basePoolTrackedBalance;
    uint256 public baseProtocolFeesAccrued;
    uint256 public marketBBadDebtBaseline;
    bool public executorIdentityViolation;

    constructor() {
        owner = vm.addr(ownerKey);
        oraclePriceX18 = 2_000e18;

        h = new PerpsInvariantHarness();
        execImpl = new PerpsExecutionFacet();
        liqImpl = new PerpsLiquidationFacet();

        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        uint256 tokenId = nft.mint(owner, POOL_ID);

        h.setPositionNft(address(nft), true);
        h.seedMarket(MARKET_A, POOL_ID, COLLATERAL_ASSET, false, false, false);
        h.seedMarket(MARKET_B, POOL_ID, COLLATERAL_ASSET, false, false, false);
        h.seedMarketState(MARKET_B, 0, 0, 123e18);
        h.seedFeePool(POOL_ID, COLLATERAL_ASSET, 1_000e18, 2_000_000e18);
        h.configureFeeRouter(0, 0, address(0));
        h.setDomainState(5_000_000e18, 0, 0);
        h.setGlobalLiquidationEnabled(true);
        h.setOracleData(oraclePriceX18, block.timestamp, 0);

        vm.prank(owner);
        bytes memory createRet =
            h.delegateTo(address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.createAccount.selector, tokenId, 0));
        accountId = abi.decode(createRet, (bytes32));

        vm.prank(owner);
        h.delegateTo(
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.addCollateral.selector,
                PerpsExecutionFacet.AddCollateralParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    collateralAsset: COLLATERAL_ASSET,
                    amount: 40_000e18
                })
            )
        );

        vm.prank(owner);
        h.delegateTo(
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.openOrIncrease.selector,
                PerpsExecutionFacet.OpenIncreaseParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    isLong: true,
                    sizeDeltaUsdX18: 2_000e18,
                    executionPriceX18: oraclePriceX18,
                    limitPriceX18: oraclePriceX18,
                    maxSlippageBps: 100,
                    feePoolId: POOL_ID,
                    executorFee: 0
                })
            )
        );

        basePoolTrackedBalance = h.getPoolTrackedBalance(POOL_ID);
        baseProtocolFeesAccrued = h.getMarketState(MARKET_A).protocolFeesAccrued;
        marketBBadDebtBaseline = h.getMarketState(MARKET_B).badDebt;
    }

    function harnessAddress() external view returns (address) {
        return address(h);
    }

    function accountIdForInvariant() external view returns (bytes32) {
        return accountId;
    }

    function actWarp(uint256 deltaSeed) external {
        uint256 dt = bound(deltaSeed, 1 minutes, 6 hours);
        vm.warp(block.timestamp + dt);
        h.setOracleData(oraclePriceX18, block.timestamp, 0);
    }

    function actSetOraclePrice(uint256 priceSeed) external {
        oraclePriceX18 = bound(priceSeed, 1_000e18, 3_000e18);
        h.setOracleData(oraclePriceX18, block.timestamp, 0);
    }

    function actAddCollateral(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e16, 1_000e18);
        _delegate(
            address(h),
            owner,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.addCollateral.selector,
                PerpsExecutionFacet.AddCollateralParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    collateralAsset: COLLATERAL_ASSET,
                    amount: amount
                })
            )
        );
    }

    function actRemoveCollateral(uint256 amountSeed) external {
        uint256 current = h.getAccountCollateral(accountId, MARKET_A);
        if (current == 0) return;
        uint256 amount = bound(amountSeed, 1, current);
        _delegate(
            address(h),
            owner,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.removeCollateral.selector,
                PerpsExecutionFacet.RemoveCollateralParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    collateralAsset: COLLATERAL_ASSET,
                    amount: amount
                })
            )
        );
    }

    function actOpenDirect(uint256 sizeSeed, uint256 sideSeed, uint256 executorFeeSeed) external {
        uint256 sizeDelta = bound(sizeSeed, 100e18, 2_000e18);
        uint256 executorFee = bound(executorFeeSeed, 0, 5e18);
        bool isLong = sideSeed % 2 == 0;
        _delegate(
            address(h),
            owner,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.openOrIncrease.selector,
                PerpsExecutionFacet.OpenIncreaseParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    isLong: isLong,
                    sizeDeltaUsdX18: sizeDelta,
                    executionPriceX18: oraclePriceX18,
                    limitPriceX18: oraclePriceX18,
                    maxSlippageBps: 100,
                    feePoolId: POOL_ID,
                    executorFee: executorFee
                })
            )
        );
    }

    function actDecreaseDirect(uint256 sizeSeed, uint256 sideSeed, uint256 executorFeeSeed) external {
        bool isLong = sideSeed % 2 == 0;
        uint256 currentSize = h.getPosition(MARKET_A, accountId, isLong).sizeUsdX18;
        if (currentSize == 0) return;

        uint256 sizeDelta = bound(sizeSeed, 1, currentSize);
        uint256 executorFee = bound(executorFeeSeed, 0, 5e18);
        _delegate(
            address(h),
            owner,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.decreaseOrClose.selector,
                PerpsExecutionFacet.DecreaseCloseParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    isLong: isLong,
                    sizeDeltaUsdX18: sizeDelta,
                    executionPriceX18: oraclePriceX18,
                    limitPriceX18: oraclePriceX18,
                    maxSlippageBps: 100,
                    feePoolId: POOL_ID,
                    executorFee: executorFee
                })
            )
        );
    }

    function actExecuteIntent(uint256 sizeSeed, uint256 actionSeed, uint256 sideSeed, uint256 executorFeeSeed) external {
        LibPerpsStorage.PerpsAccount memory account = h.getAccount(accountId);
        bool isLong = sideSeed % 2 == 0;
        uint8 action = actionSeed % 2 == 0 ? ACTION_OPEN : ACTION_CLOSE;
        uint256 executorFee = bound(executorFeeSeed, 0, 5e18);

        uint256 sizeDelta;
        if (action == ACTION_OPEN) {
            sizeDelta = bound(sizeSeed, 100e18, 1_500e18);
        } else {
            uint256 currentSize = h.getPosition(MARKET_A, accountId, isLong).sizeUsdX18;
            if (currentSize == 0) {
                action = ACTION_OPEN;
                sizeDelta = bound(sizeSeed, 100e18, 1_500e18);
            } else {
                sizeDelta = bound(sizeSeed, 1, currentSize);
            }
        }

        LibPerpsStorage.PerpsIntent memory intent = LibPerpsStorage.PerpsIntent({
            marketId: MARKET_A,
            accountId: accountId,
            action: action,
            isLong: isLong,
            sizeDeltaUsdX18: sizeDelta,
            collateralDelta: 0,
            limitPriceX18: oraclePriceX18,
            maxSlippageBps: 100,
            maxExecutorFee: 5e18,
            nonce: account.nonce,
            deadline: uint64(block.timestamp + 1 days)
        });

        (bool okDigest, bytes memory digestRet) =
            _delegate(address(h), owner, address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.intentDigest.selector, intent));
        if (!okDigest) return;
        bytes32 digest = abi.decode(digestRet, (bytes32));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address executor = actionSeed % 2 == 0 ? executorA : executorB;
        _delegate(
            address(h),
            executor,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.executeIntent.selector,
                intent,
                PerpsExecutionFacet.IntentExecutionParams({
                    signer: owner,
                    executionPriceX18: oraclePriceX18,
                    feePoolId: POOL_ID,
                    executorFee: executorFee
                }),
                signature
            )
        );
    }

    function actLiquidate(uint256 dropSeed, uint256 sideSeed, uint256 keeperSeed) external {
        bool isLong = sideSeed % 2 == 0;
        uint256 size = h.getPosition(MARKET_A, accountId, isLong).sizeUsdX18;
        if (size == 0) return;

        uint256 dropBps = bound(dropSeed, 0, 7_000);
        uint256 executionPriceX18 = (oraclePriceX18 * (10_000 - dropBps)) / 10_000;
        if (executionPriceX18 == 0) executionPriceX18 = 1;
        oraclePriceX18 = executionPriceX18;
        h.setOracleData(oraclePriceX18, block.timestamp, 0);

        address keeper = keeperSeed % 2 == 0 ? keeperA : keeperB;
        _delegate(
            address(h),
            keeper,
            address(liqImpl),
            abi.encodeWithSelector(
                PerpsLiquidationFacet.liquidate.selector,
                PerpsLiquidationFacet.LiquidationParams({
                    marketId: MARKET_A,
                    accountId: accountId,
                    isLong: isLong,
                    executionPriceX18: oraclePriceX18,
                    feePoolId: POOL_ID
                })
            )
        );
    }

    function actSyncAccount(uint256 keeperSeed) external {
        address keeper = keeperSeed % 2 == 0 ? keeperA : keeperB;
        _delegate(
            address(h),
            keeper,
            address(execImpl),
            abi.encodeWithSelector(PerpsExecutionFacet.syncAccount.selector, accountId, MARKET_A)
        );
    }

    function actSyncMarket(uint256 keeperSeed, uint256 marketSeed) external {
        address keeper = keeperSeed % 2 == 0 ? keeperA : keeperB;
        bytes32 marketId = marketSeed % 2 == 0 ? MARKET_A : MARKET_B;
        _delegate(address(h), keeper, address(liqImpl), abi.encodeWithSelector(PerpsLiquidationFacet.syncMarket.selector, marketId));
    }

    function actExecutorPermutationCheck(uint256 sizeSeed, uint256 dropSeed) external {
        _runExecutorPermutationCheck(sizeSeed, dropSeed);
    }

    function _runExecutorPermutationCheck(uint256 sizeSeed, uint256 dropSeed) internal {
        PerpsInvariantHarness a = new PerpsInvariantHarness();
        PerpsInvariantHarness b = new PerpsInvariantHarness();

        PositionNFT localNft = new PositionNFT();
        localNft.setMinter(address(this));
        uint256 localTokenId = localNft.mint(owner, POOL_ID);

        bytes32 accountA = _seedConvergenceHarness(a, localNft, localTokenId);
        bytes32 accountB = _seedConvergenceHarness(b, localNft, localTokenId);

        uint256 intentSize = bound(sizeSeed, 100e18, 1_000e18);
        LibPerpsStorage.PerpsIntent memory intent = LibPerpsStorage.PerpsIntent({
            marketId: MARKET_A,
            accountId: accountA,
            action: ACTION_OPEN,
            isLong: true,
            sizeDeltaUsdX18: intentSize,
            collateralDelta: 0,
            limitPriceX18: 2_000e18,
            maxSlippageBps: 100,
            maxExecutorFee: 0,
            nonce: a.getAccount(accountA).nonce,
            deadline: uint64(block.timestamp + 1 days)
        });

        (bool okDigestA, bytes memory digestAData) =
            _delegate(address(a), owner, address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.intentDigest.selector, intent));
        (bool okDigestB, bytes memory digestBData) =
            _delegate(address(b), owner, address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.intentDigest.selector, intent));
        if (!okDigestA || !okDigestB) {
            executorIdentityViolation = true;
            return;
        }

        bytes32 digestA = abi.decode(digestAData, (bytes32));
        bytes32 digestB = abi.decode(digestBData, (bytes32));
        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(ownerKey, digestA);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(ownerKey, digestB);

        (bool okIntentA, bytes memory retIntentA) = _delegate(
            address(a),
            executorA,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.executeIntent.selector,
                intent,
                PerpsExecutionFacet.IntentExecutionParams({
                    signer: owner,
                    executionPriceX18: 2_000e18,
                    feePoolId: POOL_ID,
                    executorFee: 0
                }),
                abi.encodePacked(rA, sA, vA)
            )
        );
        (bool okIntentB, bytes memory retIntentB) = _delegate(
            address(b),
            executorB,
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.executeIntent.selector,
                intent,
                PerpsExecutionFacet.IntentExecutionParams({
                    signer: owner,
                    executionPriceX18: 2_000e18,
                    feePoolId: POOL_ID,
                    executorFee: 0
                }),
                abi.encodePacked(rB, sB, vB)
            )
        );

        if (okIntentA != okIntentB || keccak256(retIntentA) != keccak256(retIntentB)) {
            executorIdentityViolation = true;
            return;
        }
        if (okIntentA && _stateHash(a, accountA) != _stateHash(b, accountB)) {
            executorIdentityViolation = true;
            return;
        }

        uint256 dropBps = bound(dropSeed, 0, 6_000);
        uint256 liqPrice = (2_000e18 * (10_000 - dropBps)) / 10_000;
        if (liqPrice == 0) liqPrice = 1;
        a.setOracleData(liqPrice, block.timestamp, 0);
        b.setOracleData(liqPrice, block.timestamp, 0);

        (bool okLiqA, bytes memory retLiqA) = _delegate(
            address(a),
            keeperA,
            address(liqImpl),
            abi.encodeWithSelector(
                PerpsLiquidationFacet.liquidate.selector,
                PerpsLiquidationFacet.LiquidationParams({
                    marketId: MARKET_A,
                    accountId: accountA,
                    isLong: true,
                    executionPriceX18: liqPrice,
                    feePoolId: POOL_ID
                })
            )
        );
        (bool okLiqB, bytes memory retLiqB) = _delegate(
            address(b),
            keeperB,
            address(liqImpl),
            abi.encodeWithSelector(
                PerpsLiquidationFacet.liquidate.selector,
                PerpsLiquidationFacet.LiquidationParams({
                    marketId: MARKET_A,
                    accountId: accountB,
                    isLong: true,
                    executionPriceX18: liqPrice,
                    feePoolId: POOL_ID
                })
            )
        );
        if (okLiqA != okLiqB || keccak256(retLiqA) != keccak256(retLiqB)) {
            executorIdentityViolation = true;
            return;
        }
        if (okLiqA && _stateHash(a, accountA) != _stateHash(b, accountB)) {
            executorIdentityViolation = true;
            return;
        }

        vm.warp(block.timestamp + 1 days);
        a.setOracleData(liqPrice, block.timestamp, 0);
        b.setOracleData(liqPrice, block.timestamp, 0);

        (bool okSyncAccountA, bytes memory retSyncAccountA) =
            _delegate(address(a), keeperA, address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.syncAccount.selector, accountA, MARKET_A));
        (bool okSyncAccountB, bytes memory retSyncAccountB) =
            _delegate(address(b), keeperB, address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.syncAccount.selector, accountB, MARKET_A));
        if (okSyncAccountA != okSyncAccountB || keccak256(retSyncAccountA) != keccak256(retSyncAccountB)) {
            executorIdentityViolation = true;
            return;
        }

        (bool okSyncMarketA, bytes memory retSyncMarketA) =
            _delegate(address(a), keeperA, address(liqImpl), abi.encodeWithSelector(PerpsLiquidationFacet.syncMarket.selector, MARKET_A));
        (bool okSyncMarketB, bytes memory retSyncMarketB) =
            _delegate(address(b), keeperB, address(liqImpl), abi.encodeWithSelector(PerpsLiquidationFacet.syncMarket.selector, MARKET_A));
        if (okSyncMarketA != okSyncMarketB || keccak256(retSyncMarketA) != keccak256(retSyncMarketB)) {
            executorIdentityViolation = true;
            return;
        }

        if (_stateHash(a, accountA) != _stateHash(b, accountB)) {
            executorIdentityViolation = true;
        }
    }

    function _seedConvergenceHarness(PerpsInvariantHarness hh, PositionNFT localNft, uint256 localTokenId)
        internal
        returns (bytes32 seededAccountId)
    {
        hh.setPositionNft(address(localNft), true);
        hh.seedMarket(MARKET_A, POOL_ID, COLLATERAL_ASSET, false, false, false);
        hh.seedMarket(MARKET_B, POOL_ID, COLLATERAL_ASSET, false, false, false);
        hh.seedMarketState(MARKET_B, 0, 0, 123e18);
        hh.seedFeePool(POOL_ID, COLLATERAL_ASSET, 1_000e18, 2_000_000e18);
        hh.configureFeeRouter(0, 0, address(0));
        hh.setDomainState(5_000_000e18, 0, 0);
        hh.setGlobalLiquidationEnabled(true);
        hh.setOracleData(2_000e18, block.timestamp, 0);

        vm.prank(owner);
        bytes memory createRet =
            hh.delegateTo(address(execImpl), abi.encodeWithSelector(PerpsExecutionFacet.createAccount.selector, localTokenId, 0));
        seededAccountId = abi.decode(createRet, (bytes32));

        vm.prank(owner);
        hh.delegateTo(
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.addCollateral.selector,
                PerpsExecutionFacet.AddCollateralParams({
                    marketId: MARKET_A,
                    accountId: seededAccountId,
                    collateralAsset: COLLATERAL_ASSET,
                    amount: 40_000e18
                })
            )
        );

        vm.prank(owner);
        hh.delegateTo(
            address(execImpl),
            abi.encodeWithSelector(
                PerpsExecutionFacet.openOrIncrease.selector,
                PerpsExecutionFacet.OpenIncreaseParams({
                    marketId: MARKET_A,
                    accountId: seededAccountId,
                    isLong: true,
                    sizeDeltaUsdX18: 2_000e18,
                    executionPriceX18: 2_000e18,
                    limitPriceX18: 2_000e18,
                    maxSlippageBps: 100,
                    feePoolId: POOL_ID,
                    executorFee: 0
                })
            )
        );
    }

    function _delegate(address harnessAddr, address caller, address impl, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = harnessAddr.call(abi.encodeWithSelector(PerpsInvariantHarness.delegateTo.selector, impl, data));
        if (ok) {
            ret = abi.decode(ret, (bytes));
        }
    }

    function _stateHash(PerpsInvariantHarness hh, bytes32 localAccountId) internal view returns (bytes32) {
        LibPerpsStorage.PerpsMarketState memory marketA = hh.getMarketState(MARKET_A);
        LibPerpsStorage.PerpsMarketState memory marketB = hh.getMarketState(MARKET_B);
        LibPerpsStorage.PerpsDomainState memory ds = hh.getDomainState();
        LibPerpsStorage.PerpsAccount memory account = hh.getAccount(localAccountId);
        LibPerpsStorage.PerpsPosition memory longPos = hh.getPosition(MARKET_A, localAccountId, true);
        LibPerpsStorage.PerpsPosition memory shortPos = hh.getPosition(MARKET_A, localAccountId, false);
        uint256 collateral = hh.getAccountCollateral(localAccountId, MARKET_A);
        uint256 tracked = hh.getPoolTrackedBalance(POOL_ID);
        return keccak256(abi.encode(marketA, marketB, ds, account.nonce, longPos, shortPos, collateral, tracked));
    }
}

contract PerpsInvariantTest is StdInvariant, Test {
    bytes32 internal constant MARKET_A = keccak256("perps.market.invariant.a");
    bytes32 internal constant MARKET_B = keccak256("perps.market.invariant.b");
    uint256 internal constant POOL_ID = 909;

    PerpsInvariantHandler internal handler;
    PerpsInvariantHarness internal h;

    function setUp() public {
        handler = new PerpsInvariantHandler();
        h = PerpsInvariantHarness(payable(handler.harnessAddress()));

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.actWarp.selector;
        selectors[1] = handler.actSetOraclePrice.selector;
        selectors[2] = handler.actAddCollateral.selector;
        selectors[3] = handler.actRemoveCollateral.selector;
        selectors[4] = handler.actOpenDirect.selector;
        selectors[5] = handler.actDecreaseDirect.selector;
        selectors[6] = handler.actExecuteIntent.selector;
        selectors[7] = handler.actLiquidate.selector;
        selectors[8] = handler.actSyncAccount.selector;
        selectors[9] = handler.actSyncMarket.selector;
        selectors[10] = handler.actExecutorPermutationCheck.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Invariant A: non-perps backing never decreases; increase equals explicit fee-credit accounting.
    function invariant_nonPerpsBacking_creditOnly() public {
        uint256 trackedNow = h.getPoolTrackedBalance(POOL_ID);
        uint256 trackedBase = handler.basePoolTrackedBalance();
        assertGe(trackedNow, trackedBase);

        uint256 protocolNow = h.getMarketState(MARKET_A).protocolFeesAccrued;
        uint256 protocolBase = handler.baseProtocolFeesAccrued();
        assertGe(protocolNow, protocolBase);
        assertEq(trackedNow - trackedBase, protocolNow - protocolBase);
    }

    /// @dev Invariant B: liabilities are bounded by isolated assets + insurance + recorded bad debt.
    function invariant_liabilitiesBoundedByCoverage() public {
        LibPerpsStorage.PerpsDomainState memory ds = h.getDomainState();
        LibPerpsStorage.PerpsMarketState memory a = h.getMarketState(MARKET_A);
        LibPerpsStorage.PerpsMarketState memory b = h.getMarketState(MARKET_B);
        uint256 coverage = ds.isolatedTrackedBalance + a.insuranceBalance + b.insuranceBalance + a.badDebt + b.badDebt;
        assertGe(coverage, ds.isolatedLiabilities);
    }

    /// @dev Invariant C: collateral/insurance values never go negative (unsigned state).
    function invariant_noNegativeCollateralOrInsurance() public {
        bytes32 accountId = handler.accountIdForInvariant();
        assertGe(h.getAccountCollateral(accountId, MARKET_A), 0);
        assertGe(h.getMarketState(MARKET_A).insuranceBalance, 0);
        assertGe(h.getMarketState(MARKET_B).insuranceBalance, 0);
    }

    /// @dev Invariant D: bad debt remains market-local.
    function invariant_badDebtMarketLocality() public {
        assertEq(h.getMarketState(MARKET_B).badDebt, handler.marketBBadDebtBaseline());
    }

    /// @dev Invariant E: executor identity permutations preserve validated outcomes.
    function invariant_executorIdentityConvergence() public {
        assertFalse(handler.executorIdentityViolation());
    }
}

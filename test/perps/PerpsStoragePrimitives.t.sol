// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";

contract PerpsStorageHarness {
    function storageSlotConstant() external pure returns (bytes32) {
        return LibPerpsStorage.PERPS_STORAGE_POSITION;
    }

    function setMarket(bytes32 marketId, LibPerpsStorage.PerpsMarket calldata market) external {
        LibPerpsStorage.s().markets[marketId] = market;
    }

    function getMarket(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarket memory) {
        return LibPerpsStorage.s().markets[marketId];
    }

    function setMarketState(bytes32 marketId, LibPerpsStorage.PerpsMarketState calldata marketState) external {
        LibPerpsStorage.s().marketState[marketId] = marketState;
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function setAccount(bytes32 accountId, LibPerpsStorage.PerpsAccount calldata account) external {
        LibPerpsStorage.s().accounts[accountId] = account;
    }

    function getAccount(bytes32 accountId) external view returns (LibPerpsStorage.PerpsAccount memory) {
        return LibPerpsStorage.s().accounts[accountId];
    }

    function setPosition(bytes32 marketId, bytes32 accountId, bool isLong, LibPerpsStorage.PerpsPosition calldata position)
        external
    {
        LibPerpsStorage.s().positions[marketId][accountId][isLong] = position;
    }

    function getPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory)
    {
        return LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function setDomainState(LibPerpsStorage.PerpsDomainState calldata ds) external {
        LibPerpsStorage.s().domainState = ds;
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function setIntentCanceled(bytes32 intentHash, bool canceled) external {
        LibPerpsStorage.s().canceledIntents[intentHash] = canceled;
    }

    function isIntentCanceled(bytes32 intentHash) external view returns (bool) {
        return LibPerpsStorage.s().canceledIntents[intentHash];
    }

    function setMinValidNonce(bytes32 accountId, uint64 minValidNonce) external {
        LibPerpsStorage.s().minValidNonce[accountId] = minValidNonce;
    }

    function getMinValidNonce(bytes32 accountId) external view returns (uint64) {
        return LibPerpsStorage.s().minValidNonce[accountId];
    }
}

contract PerpsStoragePrimitivesTest is Test {
    PerpsStorageHarness internal h;

    function setUp() public {
        h = new PerpsStorageHarness();
    }

    function test_storageSlot_matchesDesignSpec() public {
        assertEq(h.storageSlotConstant(), keccak256("equalis.perps.gmxstyle.storage.v1"));
    }

    function test_storage_roundTrip_marketAccountPositionAndDomain() public {
        bytes32 marketId = keccak256("perps.market.eth.usdc");
        bytes32 accountId = keccak256("perps.account.primary");

        LibPerpsStorage.PerpsMarket memory market = LibPerpsStorage.PerpsMarket({
            marketId: marketId,
            collateralPoolId: 7,
            collateralAsset: address(0xA11CE),
            indexAsset: address(0xB0B),
            longEnabled: true,
            shortEnabled: true,
            oracleAdapter: address(0x0A11),
            maxStaleness: 120,
            maxDeviationBps: 75,
            maxLeverageBps: 50_000,
            initialMarginBps: 1_000,
            maintenanceMarginBps: 700,
            liquidationIncentiveBpsMax: 500,
            maxOpenInterest: 5_000_000e18,
            maxLongOpenInterest: 3_000_000e18,
            maxShortOpenInterest: 3_000_000e18,
            maxSkewAbs: 1_000_000e18,
            takerFeeBps: 15,
            makerFeeBps: 5,
            maxFundingVelocityBpsPerDay: 1_000,
            pauseIncrease: false,
            pauseDecrease: false,
            pauseLiquidation: false,
            pauseSync: false,
            exists: true
        });

        LibPerpsStorage.PerpsMarketState memory marketState = LibPerpsStorage.PerpsMarketState({
            openInterestLong: 1_500_000e18,
            openInterestShort: 1_100_000e18,
            skew: int256(400_000e18),
            cumulativeFundingLongX18: int256(2e16),
            cumulativeFundingShortX18: -int256(2e16),
            lastFundingTs: uint64(block.timestamp),
            insuranceBalance: 100_000e18,
            insuranceTarget: 250_000e18,
            badDebt: 0,
            lpFeeIndexX18: 1_250_000_000_000_000_000,
            protocolFeesAccrued: 9_500e18,
            reservedCollateral: 500_000e18,
            realizedPnlOut: 200_000e18,
            realizedPnlIn: 180_000e18
        });

        LibPerpsStorage.PerpsAccount memory account = LibPerpsStorage.PerpsAccount({
            accountId: accountId,
            positionKey: keccak256("nft.position.key"),
            positionTokenId: 55,
            nonce: 11,
            exists: true
        });

        LibPerpsStorage.PerpsPosition memory position = LibPerpsStorage.PerpsPosition({
            isLong: true,
            sizeUsdX18: 200_000e18,
            collateralAmount: 25_000e6,
            entryPriceX18: 2_650e18,
            entryFundingX18: int256(4e15),
            realizedPnlX18: int256(12e18),
            lastIncreaseTs: uint64(block.timestamp)
        });

        LibPerpsStorage.PerpsDomainState memory domainState = LibPerpsStorage.PerpsDomainState({
            isolatedTrackedBalance: 9_000_000e18,
            isolatedLiabilities: 2_000_000e18,
            isolatedEncumbered: 1_750_000e18
        });

        h.setMarket(marketId, market);
        h.setMarketState(marketId, marketState);
        h.setAccount(accountId, account);
        h.setPosition(marketId, accountId, true, position);
        h.setDomainState(domainState);

        LibPerpsStorage.PerpsMarket memory gotMarket = h.getMarket(marketId);
        assertEq(gotMarket.marketId, market.marketId);
        assertEq(gotMarket.collateralPoolId, market.collateralPoolId);
        assertEq(gotMarket.collateralAsset, market.collateralAsset);
        assertEq(gotMarket.indexAsset, market.indexAsset);
        assertEq(gotMarket.maxLeverageBps, market.maxLeverageBps);
        assertEq(gotMarket.maxOpenInterest, market.maxOpenInterest);
        assertEq(gotMarket.takerFeeBps, market.takerFeeBps);
        assertEq(gotMarket.exists, market.exists);

        LibPerpsStorage.PerpsMarketState memory gotMarketState = h.getMarketState(marketId);
        assertEq(gotMarketState.openInterestLong, marketState.openInterestLong);
        assertEq(gotMarketState.openInterestShort, marketState.openInterestShort);
        assertEq(gotMarketState.skew, marketState.skew);
        assertEq(gotMarketState.cumulativeFundingLongX18, marketState.cumulativeFundingLongX18);
        assertEq(gotMarketState.lastFundingTs, marketState.lastFundingTs);
        assertEq(gotMarketState.insuranceBalance, marketState.insuranceBalance);
        assertEq(gotMarketState.lpFeeIndexX18, marketState.lpFeeIndexX18);

        LibPerpsStorage.PerpsAccount memory gotAccount = h.getAccount(accountId);
        assertEq(gotAccount.accountId, account.accountId);
        assertEq(gotAccount.positionKey, account.positionKey);
        assertEq(gotAccount.positionTokenId, account.positionTokenId);
        assertEq(gotAccount.nonce, account.nonce);
        assertEq(gotAccount.exists, account.exists);

        LibPerpsStorage.PerpsPosition memory gotPosition = h.getPosition(marketId, accountId, true);
        assertEq(gotPosition.isLong, position.isLong);
        assertEq(gotPosition.sizeUsdX18, position.sizeUsdX18);
        assertEq(gotPosition.collateralAmount, position.collateralAmount);
        assertEq(gotPosition.entryPriceX18, position.entryPriceX18);
        assertEq(gotPosition.entryFundingX18, position.entryFundingX18);
        assertEq(gotPosition.realizedPnlX18, position.realizedPnlX18);
        assertEq(gotPosition.lastIncreaseTs, position.lastIncreaseTs);

        LibPerpsStorage.PerpsDomainState memory gotDomain = h.getDomainState();
        assertEq(gotDomain.isolatedTrackedBalance, domainState.isolatedTrackedBalance);
        assertEq(gotDomain.isolatedLiabilities, domainState.isolatedLiabilities);
        assertEq(gotDomain.isolatedEncumbered, domainState.isolatedEncumbered);
    }

    function test_storage_roundTrip_intentCancellationAndNonceFloor() public {
        bytes32 intentHash = keccak256("intent.hash.1");
        bytes32 accountId = keccak256("perps.account.nonce-floor");

        h.setIntentCanceled(intentHash, true);
        h.setMinValidNonce(accountId, 44);

        assertTrue(h.isIntentCanceled(intentHash));
        assertEq(h.getMinValidNonce(accountId), 44);
    }
}

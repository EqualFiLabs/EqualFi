// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibReentrancyGuard} from "../../src/libraries/LibReentrancyGuard.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {PerpsLiquidationFacet} from "../../src/perps/PerpsLiquidationFacet.sol";
import {Perps_RiskLimitExceeded} from "../../src/perps/PerpsErrors.sol";

contract ReentrantTreasury {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public reentered;
    bytes4 public revertSelector;

    function configure(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
        reentered = false;
        revertSelector = bytes4(0);
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;

        (bool ok, bytes memory ret) = target.call(payload);
        if (ok) {
            reentered = true;
            return;
        }

        if (ret.length >= 4) {
            revertSelector = _selector(ret);
        }
    }

    function _selector(bytes memory ret) private pure returns (bytes4 sel) {
        assembly {
            sel := mload(add(ret, 0x20))
        }
    }
}

contract PerpsExecutionReentrancyHarness is PerpsExecutionFacet {
    uint256 internal oraclePriceX18 = 2_000e18;
    uint256 internal oracleUpdatedAt = block.timestamp;
    uint256 internal oracleDeviationBps;

    receive() external payable {}

    function setPositionNft(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setOracleData(uint256 priceX18, uint256 updatedAt, uint256 deviationBps) external {
        oraclePriceX18 = priceX18;
        oracleUpdatedAt = updatedAt;
        oracleDeviationBps = deviationBps;
    }

    function getMarkPrice(bytes32, address) external view returns (uint256 priceX18, uint256 updatedAt, uint256 deviationBps) {
        return (oraclePriceX18, oracleUpdatedAt, oracleDeviationBps);
    }

    function seedMarket(bytes32 marketId, uint256 collateralPoolId, address collateralAsset) external {
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
        market.exists = true;

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        ps.globalExecutionEnabled = true;
        ps.marketConfigMask[marketId] = 0x3f;
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

}

contract PerpsLiquidationReentrancyHarness is PerpsLiquidationFacet {
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

    function setGlobalLiquidationEnabled(bool enabled) external {
        LibPerpsStorage.s().globalLiquidationEnabled = enabled;
    }

    function seedMarket(bytes32 marketId, uint256 collateralPoolId, address collateralAsset, uint256 takerFeeBps) external {
        if (takerFeeBps > type(uint32).max) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = collateralPoolId;
        market.collateralAsset = collateralAsset;
        market.indexAsset = address(0xB0B);
        market.longEnabled = true;
        market.shortEnabled = true;
        market.initialMarginBps = 1_000;
        market.maintenanceMarginBps = 700;
        market.maxLeverageBps = 50_000;
        market.liquidationIncentiveBpsMax = 500;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = 1_000_000e18;
        market.takerFeeBps = uint32(takerFeeBps);
        market.oracleAdapter = address(this);
        market.maxStaleness = type(uint32).max;
        market.maxDeviationBps = 2_000;
        market.exists = true;
    }

    function seedMarketState(bytes32 marketId, uint256 insuranceBalance, uint256 insuranceTarget) external {
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.openInterestLong = 1_000e18;
        state.skew = int256(1_000e18);
        state.insuranceBalance = insuranceBalance;
        state.insuranceTarget = insuranceTarget;
    }

    function seedAccount(bytes32 accountId, uint256 tokenId) external {
        LibPerpsStorage.PerpsAccount storage account = LibPerpsStorage.s().accounts[accountId];
        account.accountId = accountId;
        account.positionKey = keccak256(abi.encode(accountId, tokenId));
        account.positionTokenId = tokenId;
        account.exists = true;
    }

    function setAccountCollateral(bytes32 accountId, bytes32 marketId, uint256 amount) external {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        uint256 previous = ps.accountCollateral[accountId][marketId];
        ps.accountCollateral[accountId][marketId] = amount;

        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[marketId];
        if (amount > previous) {
            state.reservedCollateral += amount - previous;
        } else if (amount < previous) {
            state.reservedCollateral -= previous - amount;
        }
    }

    function seedPosition(bytes32 marketId, bytes32 accountId, bool isLong, uint256 sizeUsdX18, uint256 entryPriceX18) external {
        LibPerpsStorage.PerpsPosition storage position = LibPerpsStorage.s().positions[marketId][accountId][isLong];
        position.isLong = isLong;
        position.sizeUsdX18 = sizeUsdX18;
        position.collateralAmount = LibPerpsStorage.s().accountCollateral[accountId][marketId];
        position.entryPriceX18 = entryPriceX18;
        position.lastIncreaseTs = uint64(block.timestamp);
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
}

contract PerpsReentrancyTest is Test {
    bytes32 internal constant MARKET_ID = keccak256("perps.market.reentrancy");
    bytes32 internal constant ACCOUNT_ID = keccak256("perps.account.reentrancy");
    uint256 internal constant POOL_ID = 777;
    address internal constant COLLATERAL_ASSET = address(0xC011A7);

    function test_openOrIncrease_blocksReentrantCallback() public {
        PerpsExecutionReentrancyHarness h = new PerpsExecutionReentrancyHarness();
        ReentrantTreasury treasury = new ReentrantTreasury();
        address owner = vm.addr(0xA11CE);

        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        uint256 tokenId = nft.mint(owner, POOL_ID);
        vm.prank(owner);
        nft.approve(address(treasury), tokenId);

        h.setPositionNft(address(nft), true);
        h.seedMarket(MARKET_ID, POOL_ID, COLLATERAL_ASSET);
        h.seedFeePool(POOL_ID, address(0), 1_000e18, 2_000_000e18);
        h.configureFeeRouter(10_000, 0, address(treasury));
        vm.deal(address(h), 100e18);

        vm.prank(address(treasury));
        bytes32 accountId = h.createAccount(tokenId, 0);

        vm.prank(address(treasury));
        h.addCollateral(
            PerpsExecutionFacet.AddCollateralParams({
                marketId: MARKET_ID,
                accountId: accountId,
                collateralAsset: COLLATERAL_ASSET,
                amount: 30_000e18
            })
        );

        PerpsExecutionFacet.OpenIncreaseParams memory p = PerpsExecutionFacet.OpenIncreaseParams({
            marketId: MARKET_ID,
            accountId: accountId,
            isLong: true,
            sizeDeltaUsdX18: 10_000e18,
            executionPriceX18: 2_000e18,
            limitPriceX18: 2_000e18,
            maxSlippageBps: 100,
            feePoolId: POOL_ID,
            executorFee: 0
        });

        treasury.configure(address(h), abi.encodeWithSelector(PerpsExecutionFacet.openOrIncrease.selector, p));

        vm.prank(address(treasury));
        h.openOrIncrease(p);

        assertTrue(treasury.attempted(), "callback should attempt reentry");
        assertFalse(treasury.reentered(), "reentry must fail");
        assertEq(
            treasury.revertSelector(),
            LibReentrancyGuard.ReentrancyGuard_ReentrantCall.selector,
            "unexpected reentry revert selector"
        );
        assertEq(h.getPosition(MARKET_ID, accountId, true).sizeUsdX18, 10_000e18, "outer execution must still succeed");
    }

    function test_liquidate_blocksReentrantCallback() public {
        PerpsLiquidationReentrancyHarness h = new PerpsLiquidationReentrancyHarness();
        ReentrantTreasury treasury = new ReentrantTreasury();

        h.seedMarket(MARKET_ID, POOL_ID, COLLATERAL_ASSET, 800);
        h.seedMarketState(MARKET_ID, 0, 0);
        h.seedAccount(ACCOUNT_ID, 1);
        h.setAccountCollateral(ACCOUNT_ID, MARKET_ID, 60e18);
        h.seedPosition(MARKET_ID, ACCOUNT_ID, true, 1_000e18, 2_000e18);
        h.setDomainState(1_000_000e18, 0, 0);
        h.setGlobalLiquidationEnabled(true);

        h.seedFeePool(POOL_ID, address(0), 1_000e18, 2_000_000e18);
        h.configureFeeRouter(10_000, 0, address(treasury));
        vm.deal(address(h), 100e18);

        PerpsLiquidationFacet.LiquidationParams memory p = PerpsLiquidationFacet.LiquidationParams({
            marketId: MARKET_ID,
            accountId: ACCOUNT_ID,
            isLong: true,
            executionPriceX18: 2_000e18,
            feePoolId: POOL_ID
        });

        treasury.configure(address(h), abi.encodeWithSelector(PerpsLiquidationFacet.liquidate.selector, p));

        (LibPerpsStorage.SettlementDelta memory delta, uint256 closeSize) = h.liquidate(p);
        assertGt(closeSize, 0);
        assertGt(delta.liquidationProtocolFee, 0);
        assertTrue(treasury.attempted(), "callback should attempt reentry");
        assertFalse(treasury.reentered(), "reentry must fail");
        assertEq(
            treasury.revertSelector(),
            LibReentrancyGuard.ReentrancyGuard_ReentrantCall.selector,
            "unexpected reentry revert selector"
        );
    }
}

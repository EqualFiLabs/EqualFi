// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterView is IIlmIsolatedIrmAdapter {
    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external pure returns (uint256 ratePerSecond) {
        return ratePerSecond;
    }
}

contract MockIlmIsolatedOracleAdapterView is IIlmIsolatedOracleAdapter {
    uint256 internal _price;
    uint256 internal _updatedAt;

    function setPrice(uint256 price, uint256 updatedAt) external {
        _price = price;
        _updatedAt = updatedAt;
    }

    function getIsolatedPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}

contract ILMIsolatedViewFacetHarness is ILMIsolatedViewFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setMaxStalenessRaw(uint256 maxStaleness) external {
        LibIlmIsolatedStorage.s().maxStaleness = maxStaleness;
    }

    function setMarket(
        bytes32 marketId,
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata params,
        IlmIsolatedTypes.IlmIsolatedMarket calldata market
    ) external {
        LibIlmIsolatedStorage.s().marketParams[marketId] = params;
        LibIlmIsolatedStorage.s().market[marketId] = market;
    }

    function setPosition(
        bytes32 marketId,
        bytes32 positionKey,
        uint256 supplyShares,
        uint128 borrowShares,
        uint128 collateralAssets
    ) external {
        IlmIsolatedTypes.IlmIsolatedPosition storage p = LibIlmIsolatedStorage.s().position[marketId][positionKey];
        p.supplyShares = supplyShares;
        p.borrowShares = borrowShares;
        p.collateralAssets = collateralAssets;
    }

    function setIrmManagedOnly(address irm_, bool managedOnly) external {
        LibIlmIsolatedStorage.s().isIrmManagedOnly[irm_] = managedOnly;
    }

    function setMarketLiquidationFeeBps(bytes32 marketId, uint16 bps) external {
        LibIlmIsolatedStorage.s().marketLiquidationFeeBps[marketId] = bps;
    }

    function setMarketProtocolFeeAssets(bytes32 marketId, uint256 assets) external {
        LibIlmIsolatedStorage.s().marketProtocolFeeAssets[marketId] = assets;
    }
}

contract ILMIsolatedViewFacetTest is Test {
    bytes32 internal constant MARKET_ID = keccak256("ilm.isolated.view.market");
    uint256 internal constant LOAN_POOL_ID = 701;
    uint256 internal constant COLLATERAL_POOL_ID = 702;
    address internal constant POSITION_OWNER = address(0xABCD);

    ILMIsolatedViewFacetHarness internal h;
    PositionNFT internal nft;
    MockIlmIsolatedIrmAdapterView internal irm;
    MockIlmIsolatedOracleAdapterView internal oracle;

    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMIsolatedViewFacetHarness();
        nft = new PositionNFT();
        irm = new MockIlmIsolatedIrmAdapterView();
        oracle = new MockIlmIsolatedOracleAdapterView();

        nft.setMinter(address(this));
        h.setPositionNftRaw(address(nft), true);
        h.setMaxStalenessRaw(1 days);
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        positionId = nft.mint(POSITION_OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);

        h.setMarket(
            MARKET_ID,
            IlmIsolatedTypes.IlmIsolatedMarketParams({
                loanPoolId: LOAN_POOL_ID,
                collateralPoolId: COLLATERAL_POOL_ID,
                oracle: address(oracle),
                irm: address(irm),
                lltv: 8e17
            }),
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 2_000_000,
                totalSupplyShares: 2_000_000,
                totalBorrowAssets: 1_000_000,
                totalBorrowShares: 1_000_000,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        h.setPosition(MARKET_ID, positionKey, 1000, 800_000, 2_000_000);
    }

    function test_getIsolatedMarket_roundTrip() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = h.getIsolatedMarket(MARKET_ID);
        assertEq(market.totalSupplyAssets, 2_000_000);
        assertEq(market.totalBorrowAssets, 1_000_000);
        assertEq(market.totalBorrowShares, 1_000_000);
    }

    function test_getIsolatedMarketParams_roundTrip() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = h.getIsolatedMarketParams(MARKET_ID);
        assertEq(params.loanPoolId, LOAN_POOL_ID);
        assertEq(params.collateralPoolId, COLLATERAL_POOL_ID);
        assertEq(params.oracle, address(oracle));
        assertEq(params.irm, address(irm));
        assertEq(params.lltv, 8e17);
    }

    function test_getIsolatedPosition_roundTrip() public {
        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getIsolatedPosition(MARKET_ID, positionKey);
        assertEq(position.supplyShares, 1000);
        assertEq(position.borrowShares, 800_000);
        assertEq(position.collateralAssets, 2_000_000);
    }

    function test_isIsolatedHealthy_revertsOnStaleOracle() public {
        vm.warp(3 days);
        uint256 updatedAt = block.timestamp - 2 days;
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, updatedAt);
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedOracleStale.selector, updatedAt, 1 days));
        h.isIsolatedHealthy(MARKET_ID, positionId);
    }

    function test_isIsolatedHealthy_roundTrip() public {
        bool healthy = h.isIsolatedHealthy(MARKET_ID, positionId);
        assertTrue(healthy);
    }

    function test_views_roundTripManagedOnlyLiquidationFeeAndProtocolClaim() public {
        h.setIrmManagedOnly(address(irm), true);
        h.setMarketLiquidationFeeBps(MARKET_ID, 125);
        h.setMarketProtocolFeeAssets(MARKET_ID, 42_000);

        assertTrue(h.isIlmIrmManagedOnly(address(irm)));
        assertEq(h.getIsolatedMarketLiquidationFeeBps(MARKET_ID), 125);
        assertEq(h.getIsolatedMarketProtocolFeeAssets(MARKET_ID), 42_000);
    }
}

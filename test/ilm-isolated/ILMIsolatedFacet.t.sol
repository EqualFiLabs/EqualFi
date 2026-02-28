// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterFacet is IIlmIsolatedIrmAdapter {
    uint256 internal _ratePerSecond;

    function setRate(uint256 ratePerSecond) external {
        _ratePerSecond = ratePerSecond;
    }

    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external view returns (uint256 ratePerSecond) {
        return _ratePerSecond;
    }
}

contract ILMIsolatedFacetHarness is ILMIsolatedFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setMarket(
        bytes32 marketId,
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata params,
        IlmIsolatedTypes.IlmIsolatedMarket calldata market,
        uint256 moduleId
    ) external {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage ds_ = LibIlmIsolatedStorage.s();
        ds_.marketParams[marketId] = params;
        ds_.market[marketId] = market;
        ds_.marketModuleId[marketId] = moduleId;
    }

    function setPositionSupplyShares(bytes32 marketId, bytes32 positionKey, uint256 shares) external {
        LibIlmIsolatedStorage.s().position[marketId][positionKey].supplyShares = shares;
    }

    function setAuthorizationRaw(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function seedModuleEncumbrance(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
    }

    function getPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory)
    {
        return LibIlmIsolatedStorage.s().position[marketId][positionKey];
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }
}

contract ILMIsolatedFacetTest is Test {
    bytes32 internal constant MARKET_ID = keccak256("ilm.isolated.market");
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant MODULE_ID = 77;
    address internal constant POSITION_OWNER = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant ATTACKER = address(0xCAFE);

    ILMIsolatedFacetHarness internal h;
    MockIlmIsolatedIrmAdapterFacet internal irm;
    PositionNFT internal nft;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public {
        h = new ILMIsolatedFacetHarness();
        irm = new MockIlmIsolatedIrmAdapterFacet();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        positionId = nft.mint(POSITION_OWNER, LOAN_POOL_ID);
        positionKey = nft.getPositionKey(positionId);
    }

    /// @dev Property 6: Supply State Consistency
    /// Validates: Requirements 2.1, 17.1
    function testFuzz_property6_supplyStateConsistency(
        uint128 totalSupplyAssetsRaw,
        uint128 totalSupplySharesRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 positionSupplySharesRaw,
        uint128 supplyAssetsRaw,
        uint128 principalBufferRaw
    ) public {
        uint256 totalSupplyAssets = bound(uint256(totalSupplyAssetsRaw), 0, 1e24);
        uint256 totalSupplyShares = bound(uint256(totalSupplySharesRaw), 0, 1e24);
        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 0, totalSupplyAssets);
        uint256 positionSupplySharesStart = bound(uint256(positionSupplySharesRaw), 0, 1e24);
        uint256 supplyAssets = bound(uint256(supplyAssetsRaw), 1, 1e24);
        uint256 principalBuffer = bound(uint256(principalBufferRaw), 0, 1e24);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: uint128(totalSupplyShares),
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionSupplyShares(MARKET_ID, positionKey, positionSupplySharesStart);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, supplyAssets + principalBuffer);

        uint256 expectedShares = LibIlmSharesMath.toSharesDown(supplyAssets, totalSupplyAssets, totalSupplyShares);
        vm.assume(totalSupplyAssets + supplyAssets <= type(uint128).max);
        vm.assume(totalSupplyShares + expectedShares <= type(uint128).max);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedSupply(MARKET_ID, supplyAssets, 0, positionId);

        assertEq(assetsOut, supplyAssets);
        assertEq(sharesOut, expectedShares);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.supplyShares, positionSupplySharesStart + expectedShares);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalSupplyAssets, totalSupplyAssets + supplyAssets);
        assertEq(gotMarket.totalSupplyShares, totalSupplyShares + expectedShares);
        assertEq(gotMarket.totalBorrowAssets, totalBorrowAssets);

        uint256 encumbered = h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID);
        assertEq(encumbered, supplyAssets);
    }

    /// @dev Property 7: Withdraw State Consistency
    /// Validates: Requirements 3.1, 17.2
    function testFuzz_property7_withdrawStateConsistency(
        bool byAssets,
        uint128 totalSupplyAssetsRaw,
        uint128 totalSupplySharesRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 positionSupplySharesRaw,
        uint128 inputRaw,
        uint128 encumberanceExtraRaw
    ) public {
        uint256 totalSupplyAssets = bound(uint256(totalSupplyAssetsRaw), 1, 1e24);
        uint256 totalSupplyShares = bound(uint256(totalSupplySharesRaw), 1, 1e24);
        uint256 positionSupplySharesStart = bound(uint256(positionSupplySharesRaw), 1, totalSupplyShares);

        uint256 sharesArg;
        uint256 assetsArg;
        uint256 assetsOutExpected;
        uint256 sharesOutExpected;

        if (byAssets) {
            assetsArg = bound(uint256(inputRaw), 1, totalSupplyAssets);
            sharesArg = 0;
            assetsOutExpected = assetsArg;
            sharesOutExpected = LibIlmSharesMath.toSharesUp(assetsArg, totalSupplyAssets, totalSupplyShares);
        } else {
            sharesArg = bound(uint256(inputRaw), 1, positionSupplySharesStart);
            assetsArg = 0;
            sharesOutExpected = sharesArg;
            assetsOutExpected = LibIlmSharesMath.toAssetsDown(sharesArg, totalSupplyAssets, totalSupplyShares);
        }

        vm.assume(sharesOutExpected <= positionSupplySharesStart);
        vm.assume(sharesOutExpected <= totalSupplyShares);
        vm.assume(assetsOutExpected <= totalSupplyAssets);

        uint256 totalBorrowAssets = bound(uint256(totalBorrowAssetsRaw), 0, totalSupplyAssets - assetsOutExpected);
        uint256 encumberedStart = assetsOutExpected + bound(uint256(encumberanceExtraRaw), 0, 1e24);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(totalSupplyAssets),
            totalSupplyShares: uint128(totalSupplyShares),
            totalBorrowAssets: uint128(totalBorrowAssets),
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPositionSupplyShares(MARKET_ID, positionKey, positionSupplySharesStart);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, encumberedStart + 1);
        h.seedModuleEncumbrance(positionKey, LOAN_POOL_ID, MODULE_ID, encumberedStart);

        vm.prank(POSITION_OWNER);
        (uint256 assetsOut, uint256 sharesOut) = h.isolatedWithdraw(MARKET_ID, assetsArg, sharesArg, positionId);

        assertEq(assetsOut, assetsOutExpected);
        assertEq(sharesOut, sharesOutExpected);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = h.getPosition(MARKET_ID, positionKey);
        assertEq(position.supplyShares, positionSupplySharesStart - sharesOutExpected);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(MARKET_ID);
        assertEq(gotMarket.totalSupplyAssets, totalSupplyAssets - assetsOutExpected);
        assertEq(gotMarket.totalSupplyShares, totalSupplyShares - sharesOutExpected);
        assertEq(gotMarket.totalBorrowAssets, totalBorrowAssets);

        uint256 encumbered = h.getEncumberedForModule(positionKey, LOAN_POOL_ID, MODULE_ID);
        assertEq(encumbered, encumberedStart - assetsOutExpected);
    }

    function test_supplyAndWithdraw_revertOnInvalidInputPairs() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 1000,
            totalSupplyShares: 1000,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1000);

        vm.startPrank(POSITION_OWNER);
        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedSupply(MARKET_ID, 0, 0, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedSupply(MARKET_ID, 1, 1, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedWithdraw(MARKET_ID, 0, 0, positionId);

        vm.expectRevert(IlmIsolatedInvalidInput.selector);
        h.isolatedWithdraw(MARKET_ID, 1, 1, positionId);
        vm.stopPrank();
    }

    function test_supply_revertsForUnauthorizedButAllowsAuthorizedOperator() public {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: 100,
            totalSupplyShares: 100,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });
        _setDefaultMarket(market);
        h.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1000);

        vm.prank(ATTACKER);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.isolatedSupply(MARKET_ID, 10, 0, positionId);

        h.setAuthorizationRaw(positionKey, OPERATOR, true);
        vm.prank(OPERATOR);
        h.isolatedSupply(MARKET_ID, 10, 0, positionId);
    }

    function _setDefaultMarket(IlmIsolatedTypes.IlmIsolatedMarket memory market) internal {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: 202,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: 8e17
        });
        h.setMarket(MARKET_ID, params, market, MODULE_ID);
    }
}

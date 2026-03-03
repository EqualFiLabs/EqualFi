// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {LibPerpsIdentity} from "../../src/perps/LibPerpsIdentity.sol";

contract PerpsIdentityHarness {
    function marketNamespace() external pure returns (bytes32) {
        return LibPerpsIdentity.MARKET_ID_NAMESPACE;
    }

    function accountNamespace() external pure returns (bytes32) {
        return LibPerpsIdentity.ACCOUNT_ID_NAMESPACE;
    }

    function positionNamespace() external pure returns (bytes32) {
        return LibPerpsIdentity.POSITION_ID_NAMESPACE;
    }

    function defaultModuleNamespace() external pure returns (bytes32) {
        return LibPerpsIdentity.DEFAULT_MODULE_NAMESPACE;
    }

    function deriveMarketId(uint256 collateralPoolId, address collateralAsset, address indexAsset)
        external
        pure
        returns (bytes32)
    {
        LibPerpsIdentity.MarketIdParams memory params = LibPerpsIdentity.MarketIdParams({
            collateralPoolId: collateralPoolId,
            collateralAsset: collateralAsset,
            indexAsset: indexAsset
        });
        return LibPerpsIdentity.deriveMarketId(params);
    }

    function deriveMarketIdFromMarket(LibPerpsStorage.PerpsMarket calldata market) external pure returns (bytes32) {
        return LibPerpsIdentity.deriveMarketId(market);
    }

    function deriveAccountId(bytes32 positionKey, uint256 subaccountNonce) external pure returns (bytes32) {
        return LibPerpsIdentity.deriveAccountId(positionKey, subaccountNonce);
    }

    function deriveAccountIdWithNamespace(bytes32 positionKey, bytes32 moduleNamespace, uint256 subaccountNonce)
        external
        pure
        returns (bytes32)
    {
        return LibPerpsIdentity.deriveAccountId(positionKey, moduleNamespace, subaccountNonce);
    }

    function derivePositionId(bytes32 marketId, bytes32 accountId, bool isLong) external pure returns (bytes32) {
        return LibPerpsIdentity.derivePositionId(marketId, accountId, isLong);
    }
}

contract PerpsIdentityTest is Test {
    PerpsIdentityHarness internal h;

    function setUp() public {
        h = new PerpsIdentityHarness();
    }

    function test_marketId_deterministicAndTupleSensitive() public {
        bytes32 idA = h.deriveMarketId(5, address(0xCA11), address(0xBEEF));
        bytes32 idB = h.deriveMarketId(5, address(0xCA11), address(0xBEEF));
        bytes32 idC = h.deriveMarketId(6, address(0xCA11), address(0xBEEF));
        bytes32 idD = h.deriveMarketId(5, address(0xCA11), address(0xBEE0));

        assertEq(idA, idB);
        assertTrue(idA != idC);
        assertTrue(idA != idD);
    }

    function test_marketId_matchesCanonicalHashingScheme() public {
        bytes32 expected = keccak256(abi.encode(h.marketNamespace(), uint256(42), address(0xA11CE), address(0xB0B)));
        bytes32 got = h.deriveMarketId(42, address(0xA11CE), address(0xB0B));
        assertEq(got, expected);
    }

    function test_marketId_overloads_match() public {
        LibPerpsStorage.PerpsMarket memory market = LibPerpsStorage.PerpsMarket({
            marketId: bytes32(0),
            collateralPoolId: 9,
            collateralAsset: address(0xAAA),
            indexAsset: address(0xBBB),
            longEnabled: true,
            shortEnabled: true,
            oracleAdapter: address(0xCCC),
            maxStaleness: 0,
            maxDeviationBps: 0,
            maxLeverageBps: 0,
            initialMarginBps: 0,
            maintenanceMarginBps: 0,
            liquidationIncentiveBpsMax: 0,
            maxOpenInterest: 0,
            maxLongOpenInterest: 0,
            maxShortOpenInterest: 0,
            maxSkewAbs: 0,
            takerFeeBps: 0,
            makerFeeBps: 0,
            maxFundingVelocityBpsPerDay: 0,
            pauseIncrease: false,
            pauseDecrease: false,
            pauseLiquidation: false,
            pauseSync: false,
            exists: false
        });

        bytes32 fromParams = h.deriveMarketId(9, address(0xAAA), address(0xBBB));
        bytes32 fromMarket = h.deriveMarketIdFromMarket(market);
        assertEq(fromParams, fromMarket);
    }

    function test_accountId_defaultNamespace_andCustomNamespace() public {
        bytes32 positionKey = keccak256("position.key");
        bytes32 customNamespace = keccak256("custom.module.namespace");

        bytes32 defaultA = h.deriveAccountId(positionKey, 0);
        bytes32 defaultB = h.deriveAccountId(positionKey, 0);
        bytes32 defaultC = h.deriveAccountId(positionKey, 1);

        assertEq(defaultA, defaultB);
        assertTrue(defaultA != defaultC);

        bytes32 expectedDefault =
            keccak256(abi.encode(h.accountNamespace(), positionKey, h.defaultModuleNamespace(), uint256(0)));
        assertEq(defaultA, expectedDefault);

        bytes32 custom = h.deriveAccountIdWithNamespace(positionKey, customNamespace, 0);
        bytes32 expectedCustom = keccak256(abi.encode(h.accountNamespace(), positionKey, customNamespace, uint256(0)));

        assertEq(custom, expectedCustom);
        assertTrue(custom != defaultA);
    }

    function test_positionId_deterministicAndSideSensitive() public {
        bytes32 marketId = keccak256("market");
        bytes32 accountId = keccak256("account");

        bytes32 longA = h.derivePositionId(marketId, accountId, true);
        bytes32 longB = h.derivePositionId(marketId, accountId, true);
        bytes32 shortPos = h.derivePositionId(marketId, accountId, false);

        assertEq(longA, longB);
        assertTrue(longA != shortPos);

        bytes32 expected = keccak256(abi.encode(h.positionNamespace(), marketId, accountId, true));
        assertEq(longA, expected);
    }
}

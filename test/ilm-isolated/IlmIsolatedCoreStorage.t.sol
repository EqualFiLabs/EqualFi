// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract LibIlmIsolatedStorageHarness {
    function setGlobals(address owner, bytes32 feeRecipientPositionKey, uint256 maxStaleness) external {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage ds = LibIlmIsolatedStorage.s();
        ds.owner = owner;
        ds.feeRecipientPositionKey = feeRecipientPositionKey;
        ds.maxStaleness = maxStaleness;
    }

    function getGlobals() external view returns (address owner, bytes32 feeRecipientPositionKey, uint256 maxStaleness) {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage ds = LibIlmIsolatedStorage.s();
        return (ds.owner, ds.feeRecipientPositionKey, ds.maxStaleness);
    }

    function setIrmEnabled(address irm, bool enabled) external {
        LibIlmIsolatedStorage.s().isIrmEnabled[irm] = enabled;
    }

    function getIrmEnabled(address irm) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isIrmEnabled[irm];
    }

    function setLltvEnabled(uint256 lltv, bool enabled) external {
        LibIlmIsolatedStorage.s().isLltvEnabled[lltv] = enabled;
    }

    function getLltvEnabled(uint256 lltv) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isLltvEnabled[lltv];
    }

    function setMarketParams(bytes32 marketId, IlmIsolatedTypes.IlmIsolatedMarketParams calldata params) external {
        LibIlmIsolatedStorage.s().marketParams[marketId] = params;
    }

    function getMarketParams(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarketParams memory) {
        return LibIlmIsolatedStorage.s().marketParams[marketId];
    }

    function setMarket(bytes32 marketId, IlmIsolatedTypes.IlmIsolatedMarket calldata market) external {
        LibIlmIsolatedStorage.s().market[marketId] = market;
    }

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
    }

    function setPosition(
        bytes32 marketId,
        bytes32 positionKey,
        IlmIsolatedTypes.IlmIsolatedPosition calldata position
    ) external {
        LibIlmIsolatedStorage.s().position[marketId][positionKey] = position;
    }

    function getPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory)
    {
        return LibIlmIsolatedStorage.s().position[marketId][positionKey];
    }

    function setAuthorization(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function getAuthorization(bytes32 positionKey, address operator) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator];
    }

    function setMarketModuleId(bytes32 marketId, uint256 moduleId) external {
        LibIlmIsolatedStorage.s().marketModuleId[marketId] = moduleId;
    }

    function getMarketModuleId(bytes32 marketId) external view returns (uint256) {
        return LibIlmIsolatedStorage.s().marketModuleId[marketId];
    }

    function deriveMarketIdFromCalldata(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params)
        external
        pure
        returns (bytes32)
    {
        return LibIlmIsolatedStorage.deriveMarketId(params);
    }

    function deriveMarketIdFromMemory(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params)
        external
        pure
        returns (bytes32)
    {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory memParams = params;
        return LibIlmIsolatedStorage.deriveMarketId(memParams);
    }
}

contract IlmIsolatedCoreStorageTest is Test {
    LibIlmIsolatedStorageHarness internal h;

    function setUp() public {
        h = new LibIlmIsolatedStorageHarness();
    }

    function test_constants_matchDesignSpec() public {
        assertEq(IlmIsolatedTypes.WAD, 1e18);
        assertEq(IlmIsolatedTypes.ORACLE_PRICE_SCALE, 1e36);
        assertEq(IlmIsolatedTypes.LIQUIDATION_CURSOR, 3e17);
        assertEq(IlmIsolatedTypes.MAX_LIQUIDATION_INCENTIVE_FACTOR, 115e16);
        assertEq(IlmIsolatedTypes.MAX_FEE, 25e16);
        assertEq(IlmIsolatedTypes.VIRTUAL_SHARES, 1e6);
        assertEq(IlmIsolatedTypes.VIRTUAL_ASSETS, 1);
    }

    function test_marketIdDerivation_matchesKeccakAbiEncode() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 101,
            collateralPoolId: 202,
            oracle: address(0x1111),
            irm: address(0x2222),
            lltv: 8e17
        });

        bytes32 expected = keccak256(abi.encode(params));
        bytes32 fromCalldata = h.deriveMarketIdFromCalldata(params);
        bytes32 fromMemory = h.deriveMarketIdFromMemory(params);

        assertEq(fromCalldata, expected);
        assertEq(fromMemory, expected);
    }

    function test_storage_roundTrip_globalsFlagsMappings() public {
        bytes32 marketId = keccak256("market");
        bytes32 positionKey = keccak256("position");

        h.setGlobals(address(0xABCD), bytes32(uint256(77)), 2 days);
        h.setIrmEnabled(address(0xBEEF), true);
        h.setLltvEnabled(9e17, true);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 11,
            collateralPoolId: 22,
            oracle: address(0x3333),
            irm: address(0x4444),
            lltv: 9e17
        });
        h.setMarketParams(marketId, params);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: uint128(1_000_000),
            totalSupplyShares: uint128(900_000),
            totalBorrowAssets: uint128(500_000),
            totalBorrowShares: uint128(450_000),
            lastUpdate: uint128(block.timestamp),
            fee: uint128(15e16)
        });
        h.setMarket(marketId, market);

        IlmIsolatedTypes.IlmIsolatedPosition memory position = IlmIsolatedTypes.IlmIsolatedPosition({
            supplyShares: 123_456_789,
            borrowShares: uint128(123_000),
            collateralAssets: uint128(456_000)
        });
        h.setPosition(marketId, positionKey, position);

        h.setAuthorization(positionKey, address(0xCAFE), true);
        h.setMarketModuleId(marketId, 42);

        (address owner, bytes32 feeRecipientPositionKey, uint256 maxStaleness) = h.getGlobals();
        assertEq(owner, address(0xABCD));
        assertEq(feeRecipientPositionKey, bytes32(uint256(77)));
        assertEq(maxStaleness, 2 days);

        assertTrue(h.getIrmEnabled(address(0xBEEF)));
        assertTrue(h.getLltvEnabled(9e17));

        IlmIsolatedTypes.IlmIsolatedMarketParams memory gotParams = h.getMarketParams(marketId);
        assertEq(gotParams.loanPoolId, params.loanPoolId);
        assertEq(gotParams.collateralPoolId, params.collateralPoolId);
        assertEq(gotParams.oracle, params.oracle);
        assertEq(gotParams.irm, params.irm);
        assertEq(gotParams.lltv, params.lltv);

        IlmIsolatedTypes.IlmIsolatedMarket memory gotMarket = h.getMarket(marketId);
        assertEq(gotMarket.totalSupplyAssets, market.totalSupplyAssets);
        assertEq(gotMarket.totalSupplyShares, market.totalSupplyShares);
        assertEq(gotMarket.totalBorrowAssets, market.totalBorrowAssets);
        assertEq(gotMarket.totalBorrowShares, market.totalBorrowShares);
        assertEq(gotMarket.lastUpdate, market.lastUpdate);
        assertEq(gotMarket.fee, market.fee);

        IlmIsolatedTypes.IlmIsolatedPosition memory gotPosition = h.getPosition(marketId, positionKey);
        assertEq(gotPosition.supplyShares, position.supplyShares);
        assertEq(gotPosition.borrowShares, position.borrowShares);
        assertEq(gotPosition.collateralAssets, position.collateralAssets);

        assertTrue(h.getAuthorization(positionKey, address(0xCAFE)));
        assertEq(h.getMarketModuleId(marketId), 42);
    }

    function test_errorSelectors_matchDeclaredSignatures() public {
        assertEq(
            IlmIsolatedMarketNotCreated.selector, bytes4(keccak256("IlmIsolatedMarketNotCreated(bytes32)"))
        );
        assertEq(
            IlmIsolatedMarketAlreadyCreated.selector, bytes4(keccak256("IlmIsolatedMarketAlreadyCreated(bytes32)"))
        );
        assertEq(IlmIsolatedInvalidInput.selector, bytes4(keccak256("IlmIsolatedInvalidInput()")));
        assertEq(IlmIsolatedZeroAddress.selector, bytes4(keccak256("IlmIsolatedZeroAddress()")));
        assertEq(IlmIsolatedUnauthorized.selector, bytes4(keccak256("IlmIsolatedUnauthorized()")));
        assertEq(
            IlmIsolatedInsufficientLiquidity.selector,
            bytes4(keccak256("IlmIsolatedInsufficientLiquidity(uint256,uint256)"))
        );
        assertEq(IlmIsolatedInsufficientCollateral.selector, bytes4(keccak256("IlmIsolatedInsufficientCollateral()")));
        assertEq(IlmIsolatedHealthyPosition.selector, bytes4(keccak256("IlmIsolatedHealthyPosition()")));
        assertEq(IlmIsolatedIrmNotEnabled.selector, bytes4(keccak256("IlmIsolatedIrmNotEnabled(address)")));
        assertEq(IlmIsolatedLltvNotEnabled.selector, bytes4(keccak256("IlmIsolatedLltvNotEnabled(uint256)")));
        assertEq(IlmIsolatedFeeTooHigh.selector, bytes4(keccak256("IlmIsolatedFeeTooHigh(uint256,uint256)")));
        assertEq(IlmIsolatedOracleStale.selector, bytes4(keccak256("IlmIsolatedOracleStale(uint256,uint256)")));
    }
}

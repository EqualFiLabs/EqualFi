// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../src/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {ModulePausedError} from "../../src/libraries/Errors.sol";

contract LibIlmStorageHarness {
    function setGlobals(
        uint256 nextMarketId,
        address oracleAdapter,
        address sentinelAdapter,
        uint16 minLtvBps,
        uint16 maxLtvBps,
        uint16 minReserveFactorBps,
        uint16 maxReserveFactorBps
    ) external {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        ds.nextMarketId = nextMarketId;
        ds.oracleAdapter = oracleAdapter;
        ds.sentinelAdapter = sentinelAdapter;
        ds.minLtvBps = minLtvBps;
        ds.maxLtvBps = maxLtvBps;
        ds.minReserveFactorBps = minReserveFactorBps;
        ds.maxReserveFactorBps = maxReserveFactorBps;
    }

    function getGlobals()
        external
        view
        returns (
            uint256 nextMarketId,
            address oracleAdapter,
            address sentinelAdapter,
            uint16 minLtvBps,
            uint16 maxLtvBps,
            uint16 minReserveFactorBps,
            uint16 maxReserveFactorBps
        )
    {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        return (
            ds.nextMarketId,
            ds.oracleAdapter,
            ds.sentinelAdapter,
            ds.minLtvBps,
            ds.maxLtvBps,
            ds.minReserveFactorBps,
            ds.maxReserveFactorBps
        );
    }

    function setMarket(uint256 marketId, IlmTypes.IlmMarket calldata market) external {
        LibIlmStorage.s().markets[marketId] = market;
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }

    function setPosition(uint256 marketId, bytes32 positionKey, IlmTypes.IlmPosition calldata position) external {
        LibIlmStorage.s().positions[marketId][positionKey] = position;
    }

    function getPosition(uint256 marketId, bytes32 positionKey) external view returns (IlmTypes.IlmPosition memory) {
        return LibIlmStorage.s().positions[marketId][positionKey];
    }

    function setMarketModuleId(uint256 marketId, uint256 moduleId) external {
        LibIlmStorage.s().marketModuleId[marketId] = moduleId;
    }

    function getMarketModuleId(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketModuleId[marketId];
    }

    function setMarketProtocolFeeAssets(uint256 marketId, uint256 assets) external {
        LibIlmStorage.s().marketProtocolFeeAssets[marketId] = assets;
    }

    function getMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketProtocolFeeAssets[marketId];
    }

    function setAuthorization(bytes32 positionKey, address operator, bool authorized) external {
        LibIlmStorage.s().isAuthorizedOperator[positionKey][operator] = authorized;
    }

    function getAuthorization(bytes32 positionKey, address operator) external view returns (bool) {
        return LibIlmStorage.s().isAuthorizedOperator[positionKey][operator];
    }

    function storageSlotConstant() external pure returns (bytes32) {
        return LibIlmStorage.STORAGE_POSITION;
    }
}

contract IlmPooledCoreStorageTest is Test {
    LibIlmStorageHarness internal h;

    function setUp() public {
        h = new LibIlmStorageHarness();
    }

    function test_constants_matchDesignSpec() public {
        assertEq(IlmTypes.RAY, 1e27);
        assertEq(IlmTypes.WAD, 1e18);
        assertEq(IlmTypes.BPS, 10_000);
        assertEq(IlmTypes.HF_PRECISION, 1e18);
        assertEq(IlmTypes.CLOSE_FACTOR_HF_THRESHOLD, 95e16);
        assertEq(IlmTypes.DEFAULT_CLOSE_FACTOR_BPS, 5_000);
        assertEq(IlmTypes.SECONDS_PER_YEAR, 365 days);
    }

    function test_storageSlot_matchesSpec() public {
        assertEq(h.storageSlotConstant(), keccak256("equalis.ilm.pooled.storage"));
    }

    function test_storage_roundTrip_globalsMarketPositionAndMappings() public {
        uint256 marketId = 42;
        bytes32 positionKey = keccak256("pooled.position");

        h.setGlobals(99, address(0x1111), address(0x2222), 1000, 9000, 0, 5000);

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: 101,
            collateralPoolId: 202,
            ltvBps: 7500,
            liquidationThresholdBps: 8000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 150,
            reserveFactorBps: 1000,
            optimalUtilizationBps: 8000,
            baseVariableRateRayPerYear: 1_000_000,
            variableSlope1RayPerYear: 2_000_000,
            variableSlope2RayPerYear: 5_000_000,
            supplyCap: 1_000_000e18,
            borrowCap: 700_000e18,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(1e27),
            variableBorrowIndexRay: uint128(1e27),
            currentLiquidityRateRay: uint128(2e25),
            currentVariableBorrowRateRay: uint128(5e25),
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 1_234_567,
            scaledVariableDebtTotal: 654_321,
            availableLiquidity: 500_000e18,
            badDebt: 0
        });

        IlmTypes.IlmPosition memory position = IlmTypes.IlmPosition({
            scaledSupply: 123_456,
            scaledDebt: 42_000,
            useAsCollateral: true
        });

        h.setMarket(marketId, market);
        h.setPosition(marketId, positionKey, position);
        h.setMarketModuleId(marketId, 777);
        h.setMarketProtocolFeeAssets(marketId, 12_345e18);
        h.setAuthorization(positionKey, address(0xCAFE), true);

        (
            uint256 nextMarketId,
            address oracleAdapter,
            address sentinelAdapter,
            uint16 minLtvBps,
            uint16 maxLtvBps,
            uint16 minReserveFactorBps,
            uint16 maxReserveFactorBps
        ) = h.getGlobals();

        assertEq(nextMarketId, 99);
        assertEq(oracleAdapter, address(0x1111));
        assertEq(sentinelAdapter, address(0x2222));
        assertEq(minLtvBps, 1000);
        assertEq(maxLtvBps, 9000);
        assertEq(minReserveFactorBps, 0);
        assertEq(maxReserveFactorBps, 5000);

        IlmTypes.IlmMarket memory gotMarket = h.getMarket(marketId);
        assertEq(gotMarket.loanPoolId, market.loanPoolId);
        assertEq(gotMarket.collateralPoolId, market.collateralPoolId);
        assertEq(gotMarket.ltvBps, market.ltvBps);
        assertEq(gotMarket.liquidationThresholdBps, market.liquidationThresholdBps);
        assertEq(gotMarket.liquidationBonusBps, market.liquidationBonusBps);
        assertEq(gotMarket.liquidationProtocolFeeBps, market.liquidationProtocolFeeBps);
        assertEq(gotMarket.reserveFactorBps, market.reserveFactorBps);
        assertEq(gotMarket.optimalUtilizationBps, market.optimalUtilizationBps);
        assertEq(gotMarket.baseVariableRateRayPerYear, market.baseVariableRateRayPerYear);
        assertEq(gotMarket.variableSlope1RayPerYear, market.variableSlope1RayPerYear);
        assertEq(gotMarket.variableSlope2RayPerYear, market.variableSlope2RayPerYear);
        assertEq(gotMarket.supplyCap, market.supplyCap);
        assertEq(gotMarket.borrowCap, market.borrowCap);
        assertEq(gotMarket.active, market.active);
        assertEq(gotMarket.paused, market.paused);
        assertEq(gotMarket.frozen, market.frozen);
        assertEq(gotMarket.liquidityIndexRay, market.liquidityIndexRay);
        assertEq(gotMarket.variableBorrowIndexRay, market.variableBorrowIndexRay);
        assertEq(gotMarket.currentLiquidityRateRay, market.currentLiquidityRateRay);
        assertEq(gotMarket.currentVariableBorrowRateRay, market.currentVariableBorrowRateRay);
        assertEq(gotMarket.lastUpdate, market.lastUpdate);
        assertEq(gotMarket.scaledSupplyTotal, market.scaledSupplyTotal);
        assertEq(gotMarket.scaledVariableDebtTotal, market.scaledVariableDebtTotal);
        assertEq(gotMarket.availableLiquidity, market.availableLiquidity);
        assertEq(gotMarket.badDebt, market.badDebt);

        IlmTypes.IlmPosition memory gotPosition = h.getPosition(marketId, positionKey);
        assertEq(gotPosition.scaledSupply, position.scaledSupply);
        assertEq(gotPosition.scaledDebt, position.scaledDebt);
        assertEq(gotPosition.useAsCollateral, position.useAsCollateral);

        assertEq(h.getMarketModuleId(marketId), 777);
        assertEq(h.getMarketProtocolFeeAssets(marketId), 12_345e18);
        assertTrue(h.getAuthorization(positionKey, address(0xCAFE)));
    }

    function test_errorSelectors_matchDeclaredSignatures() public {
        assertEq(IlmMarketNotFound.selector, bytes4(keccak256("IlmMarketNotFound(uint256)")));
        assertEq(IlmReserveInactive.selector, bytes4(keccak256("IlmReserveInactive(uint256)")));
        assertEq(IlmReservePaused.selector, bytes4(keccak256("IlmReservePaused(uint256)")));
        assertEq(IlmReserveFrozen.selector, bytes4(keccak256("IlmReserveFrozen(uint256)")));
        assertEq(
            IlmSupplyCapExceeded.selector, bytes4(keccak256("IlmSupplyCapExceeded(uint256,uint256)"))
        );
        assertEq(
            IlmBorrowCapExceeded.selector, bytes4(keccak256("IlmBorrowCapExceeded(uint256,uint256)"))
        );
        assertEq(
            IlmInsufficientLiquidity.selector,
            bytes4(keccak256("IlmInsufficientLiquidity(uint256,uint256)"))
        );
        assertEq(
            IlmUnsafePosition.selector, bytes4(keccak256("IlmUnsafePosition(uint256,uint256)"))
        );
        assertEq(IlmNotLiquidatable.selector, bytes4(keccak256("IlmNotLiquidatable(uint256)")));
        assertEq(IlmSentinelBlocked.selector, bytes4(keccak256("IlmSentinelBlocked()")));
        assertEq(IlmInvalidRiskParams.selector, bytes4(keccak256("IlmInvalidRiskParams()")));
        assertEq(IlmNotGovernance.selector, bytes4(keccak256("IlmNotGovernance()")));
        assertEq(IlmUnauthorized.selector, bytes4(keccak256("IlmUnauthorized()")));
        assertEq(ModulePausedError.selector, bytes4(keccak256("ModulePausedError(uint256)")));
    }
}

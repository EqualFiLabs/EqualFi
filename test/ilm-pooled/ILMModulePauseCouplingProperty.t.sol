// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {IlmTypes} from "../../src/libraries/IlmTypes.sol";
import {ILMPooledFacet} from "../../src/modules/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../../src/modules/ILMPooledLiquidationFacet.sol";
import {ModulePausedError} from "../../src/libraries/Errors.sol";

contract ILMPooledFacetHarnessModulePause is ILMPooledFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setModuleStateRaw(uint256 moduleId, bool paused, bool inactive) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = paused;
        ms.modules[moduleId].inactive = inactive;
    }

    function setMarketRaw(uint256 marketId, IlmTypes.IlmMarket calldata market, uint256 moduleId) external {
        LibIlmStorage.s().markets[marketId] = market;
        LibIlmStorage.s().marketModuleId[marketId] = moduleId;
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = false;
        ms.modules[moduleId].inactive = false;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }
}

contract ILMPooledLiquidationHarnessModulePause is ILMPooledLiquidationFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setModuleStateRaw(uint256 moduleId, bool paused, bool inactive) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = paused;
        ms.modules[moduleId].inactive = inactive;
    }

    function setMarketRaw(uint256 marketId, IlmTypes.IlmMarket calldata market, uint256 moduleId) external {
        LibIlmStorage.s().markets[marketId] = market;
        LibIlmStorage.s().marketModuleId[marketId] = moduleId;
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.modules[moduleId].paused = false;
        ms.modules[moduleId].inactive = false;
    }
}

contract ILMModulePauseCouplingPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;
    uint256 internal constant MODULE_ID = 77;

    address internal constant OWNER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B0);
    address internal constant LIQUIDATOR = address(0xCAFE);

    ILMPooledFacetHarnessModulePause internal h;
    ILMPooledLiquidationHarnessModulePause internal hl;
    PositionNFT internal nft;

    uint256 internal ownerPositionId;
    bytes32 internal ownerPositionKey;
    uint256 internal borrowerPositionId;
    uint256 internal liquidatorPositionId;

    function setUp() public {
        h = new ILMPooledFacetHarnessModulePause();
        hl = new ILMPooledLiquidationHarnessModulePause();
        nft = new PositionNFT();
        nft.setMinter(address(this));

        h.setPositionNftRaw(address(nft), true);
        hl.setPositionNftRaw(address(nft), true);

        ownerPositionId = nft.mint(OWNER, LOAN_POOL_ID);
        ownerPositionKey = nft.getPositionKey(ownerPositionId);
        borrowerPositionId = nft.mint(BORROWER, LOAN_POOL_ID);
        liquidatorPositionId = nft.mint(LIQUIDATOR, LOAN_POOL_ID);
    }

    /// @dev Property 32: bound module pause blocks all ILM pooled mutations.
    function test_property32_modulePauseCoupling_allMutationsRevert() public {
        IlmTypes.IlmMarket memory market = _market();
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        hl.setMarketRaw(MARKET_ID, market, MODULE_ID);

        h.setModuleStateRaw(MODULE_ID, true, false);
        hl.setModuleStateRaw(MODULE_ID, true, false);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledSupply(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledWithdraw(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledBorrow(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledRepay(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledAddCollateral(ownerPositionId, MARKET_ID, 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        h.pooledRemoveCollateral(ownerPositionId, MARKET_ID, 1);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        hl.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, MARKET_ID, 1);
    }

    /// @dev Property 32/Requirement 16.3: module inactive alone does not block pooled operations.
    function test_property32_moduleInactiveDoesNotBlock() public {
        IlmTypes.IlmMarket memory market = _market();
        h.setMarketRaw(MARKET_ID, market, MODULE_ID);
        h.setModuleStateRaw(MODULE_ID, false, true);
        h.setPoolPrincipal(LOAN_POOL_ID, ownerPositionKey, 100);

        vm.prank(OWNER);
        h.pooledSupply(ownerPositionId, MARKET_ID, 10);

        IlmTypes.IlmMarket memory got = h.getMarket(MARKET_ID);
        assertEq(got.availableLiquidity, 10);
        assertEq(got.scaledSupplyTotal, 10);
    }

    function _market() internal view returns (IlmTypes.IlmMarket memory market) {
        market = IlmTypes.IlmMarket({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            ltvBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 0,
            liquidationProtocolFeeBps: 0,
            reserveFactorBps: 1_000,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: type(uint256).max,
            borrowCap: type(uint256).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: 0,
            availableLiquidity: 0,
            badDebt: 0
        });
    }
}

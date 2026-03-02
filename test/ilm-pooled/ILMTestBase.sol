// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IModuleRegistryFacet} from "../../src/interfaces/IModuleRegistryFacet.sol";
import {IILMPooledAdminFacet} from "../../src/ilm-pooled/interfaces/IILMPooledAdminFacet.sol";
import {IILMPooledFacet} from "../../src/ilm-pooled/interfaces/IILMPooledFacet.sol";
import {IILMPooledLiquidationFacet} from "../../src/ilm-pooled/interfaces/IILMPooledLiquidationFacet.sol";
import {IILMPooledViewFacet} from "../../src/ilm-pooled/interfaces/IILMPooledViewFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ILMPooledAdminFacet} from "../../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../../src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol";
import {ILMPooledViewFacet} from "../../src/ilm-pooled/facets/ILMPooledViewFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";
import {IlmTypes} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {IIlmOracleAdapter} from "../../src/ilm-pooled/interfaces/IIlmOracleAdapter.sol";
import {IIlmSentinelAdapter} from "../../src/ilm-pooled/interfaces/IIlmSentinelAdapter.sol";

interface IILMTestHarness {
    function setPositionNftRaw(address nft, bool enabled) external;
    function seedPool(uint256 poolId, address underlying) external;
    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external;
    function setPoolTotalsAndTracked(uint256 poolId, uint256 totalDeposits, uint256 trackedBalance) external;
    function setGlobalFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external;
    function setTreasury(address treasury) external;
    function setModuleAciPausedRaw(bool paused) external;
    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256);
    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256);
    function getPoolActiveCreditPrincipalTotal(uint256 poolId) external view returns (uint256);
    function getPoolUserActiveCreditEncumbrancePrincipal(uint256 poolId, bytes32 positionKey)
        external
        view
        returns (uint256);
    function getModuleAciPausedRaw() external view returns (bool);
    function getAvailablePrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256);
}

contract MockIlmOracleAdapterIntegration is IIlmOracleAdapter {
    uint256 internal _priceRay;

    constructor() {
        _priceRay = 1e27;
    }

    function setPriceRay(uint256 priceRay) external {
        _priceRay = priceRay;
    }

    function getPrice(uint256, uint256) external view returns (uint256 priceRay) {
        return _priceRay;
    }
}

contract MockIlmSentinelAdapterIntegration is IIlmSentinelAdapter {
    bool internal _borrowAllowed = true;
    bool internal _liquidationAllowed = true;

    function setBorrowAllowed(bool allowed) external {
        _borrowAllowed = allowed;
    }

    function setLiquidationAllowed(bool allowed) external {
        _liquidationAllowed = allowed;
    }

    function isBorrowAllowed() external view returns (bool) {
        return _borrowAllowed;
    }

    function isLiquidationAllowed() external view returns (bool) {
        return _liquidationAllowed;
    }
}

contract ILMTestHarnessFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function seedPool(uint256 poolId, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[poolId];
        p.underlying = underlying;
        p.initialized = true;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = 8_000;
        }
        if (p.lastMaintenanceTimestamp == 0) {
            p.lastMaintenanceTimestamp = uint64(block.timestamp);
        }
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[poolId];
        p.initialized = true;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function setPoolTotalsAndTracked(uint256 poolId, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[poolId];
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
    }

    function setGlobalFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) {
            revert();
        }
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.treasuryShareConfigured = true;
        app.treasuryShareBps = uint16(treasuryBps);
        app.activeCreditShareConfigured = true;
        app.activeCreditShareBps = uint16(activeCreditBps);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setModuleAciPausedRaw(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
    }

    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, moduleId);
    }

    function getPoolActiveCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function getPoolUserActiveCreditEncumbrancePrincipal(uint256 poolId, bytes32 positionKey)
        external
        view
        returns (uint256)
    {
        return LibAppStorage.s().pools[poolId].userActiveCreditStateEncumbrance[positionKey].principal;
    }

    function getModuleAciPausedRaw() external view returns (bool) {
        return LibModuleRegistry.s().moduleAciPaused;
    }

    function getAvailablePrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibSolvencyChecks.calculateAvailablePrincipal(LibAppStorage.s().pools[poolId], positionKey, poolId);
    }
}

abstract contract ILMTestBase is Test {
    uint256 internal constant LOAN_POOL_ID = 101;
    uint256 internal constant COLLATERAL_POOL_ID = 202;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B0);
    address internal constant CAROL = address(0xCAFE);

    Diamond internal diamond;

    IILMPooledAdminFacet internal pooledAdmin;
    IILMPooledFacet internal pooled;
    IILMPooledLiquidationFacet internal pooledLiquidation;
    IILMPooledViewFacet internal pooledView;
    IModuleRegistryFacet internal moduleRegistry;
    IILMTestHarness internal harness;

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    PositionNFT internal nft;
    MockIlmOracleAdapterIntegration internal oracle;
    MockIlmSentinelAdapterIntegration internal sentinel;

    uint256 internal moduleId;

    function setUpBase() internal {
        _deployDiamondAndFacets();
        _wireInterfaces();
        _deployMocks();
        _configureBaseState();
    }

    function _deployDiamondAndFacets() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        ModuleRegistryFacet moduleRegistryFacet = new ModuleRegistryFacet();
        ILMPooledAdminFacet adminFacet = new ILMPooledAdminFacet();
        ILMPooledFacet pooledFacet = new ILMPooledFacet();
        ILMPooledLiquidationFacet liqFacet = new ILMPooledLiquidationFacet();
        ILMPooledViewFacet viewFacet = new ILMPooledViewFacet();
        ILMTestHarnessFacet harnessFacet = new ILMTestHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(moduleRegistryFacet), _selectorsModuleRegistry());
        cuts[2] = _cut(address(adminFacet), _selectorsPooledAdmin());
        cuts[3] = _cut(address(pooledFacet), _selectorsPooled());
        cuts[4] = _cut(address(liqFacet), _selectorsPooledLiquidation());
        cuts[5] = _cut(address(viewFacet), _selectorsPooledView());
        cuts[6] = _cut(address(harnessFacet), _selectorsHarness());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
    }

    function _wireInterfaces() internal {
        pooledAdmin = IILMPooledAdminFacet(address(diamond));
        pooled = IILMPooledFacet(address(diamond));
        pooledLiquidation = IILMPooledLiquidationFacet(address(diamond));
        pooledView = IILMPooledViewFacet(address(diamond));
        moduleRegistry = IModuleRegistryFacet(address(diamond));
        harness = IILMTestHarness(address(diamond));
    }

    function _deployMocks() internal {
        loanToken = new MockERC20("Loan Token", "LOAN", 18, 1_000_000 ether);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18, 1_000_000 ether);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        oracle = new MockIlmOracleAdapterIntegration();
        sentinel = new MockIlmSentinelAdapterIntegration();
    }

    function _configureBaseState() internal {
        harness.setPositionNftRaw(address(nft), true);
        harness.seedPool(LOAN_POOL_ID, address(loanToken));
        harness.seedPool(COLLATERAL_POOL_ID, address(collateralToken));
        harness.setGlobalFeeSplits(0, 0);
        harness.setTreasury(address(0));

        pooledAdmin.setPooledGlobalBounds(1, 9_500, 0, 10_000);
        pooledAdmin.setPooledOracleAdapter(address(oracle));
        pooledAdmin.setPooledSentinelAdapter(address(sentinel));

        moduleId = moduleRegistry.registerModule(keccak256("ILM_POOLED_TEST"));
    }

    function createDefaultMarket(uint16 liquidationBonusBps, uint16 liquidationProtocolFeeBps)
        internal
        returns (uint256 marketId)
    {
        IlmTypes.IlmCreateParams memory params = IlmTypes.IlmCreateParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            moduleId: moduleId,
            ltvBps: 7_500,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: liquidationBonusBps,
            liquidationProtocolFeeBps: liquidationProtocolFeeBps,
            reserveFactorBps: 0,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 0,
            variableSlope1RayPerYear: 0,
            variableSlope2RayPerYear: 0,
            supplyCap: type(uint256).max,
            borrowCap: type(uint256).max
        });
        return pooledAdmin.createPooledMarket(params);
    }

    function mintPosition(address owner, uint256 poolId) internal returns (uint256 positionId, bytes32 positionKey) {
        positionId = nft.mint(owner, poolId);
        positionKey = nft.getPositionKey(positionId);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsModuleRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = IModuleRegistryFacet.registerModule.selector;
        s[1] = IModuleRegistryFacet.setModuleOwner.selector;
        s[2] = IModuleRegistryFacet.pauseModule.selector;
        s[3] = IModuleRegistryFacet.unpauseModule.selector;
        s[4] = IModuleRegistryFacet.setModuleCreationFee.selector;
        s[5] = IModuleRegistryFacet.setDefaultModuleAumBps.selector;
        s[6] = IModuleRegistryFacet.setModuleAumBps.selector;
        s[7] = IModuleRegistryFacet.setModuleAumBounds.selector;
        s[8] = IModuleRegistryFacet.setModuleDeactivationGraceEpochs.selector;
        s[9] = IModuleRegistryFacet.setModuleAciPaused.selector;
    }

    function _selectorsPooledAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = IILMPooledAdminFacet.createPooledMarket.selector;
        s[1] = IILMPooledAdminFacet.setPooledMarketFlags.selector;
        s[2] = IILMPooledAdminFacet.setPooledMarketCaps.selector;
        s[3] = IILMPooledAdminFacet.setPooledRiskParams.selector;
        s[4] = IILMPooledAdminFacet.setPooledRateStrategy.selector;
        s[5] = IILMPooledAdminFacet.setPooledOracleAdapter.selector;
        s[6] = IILMPooledAdminFacet.setPooledSentinelAdapter.selector;
        s[7] = IILMPooledAdminFacet.setPooledGlobalBounds.selector;
    }

    function _selectorsPooled() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IILMPooledFacet.pooledSupply.selector;
        s[1] = IILMPooledFacet.pooledWithdraw.selector;
        s[2] = IILMPooledFacet.pooledAddCollateral.selector;
        s[3] = IILMPooledFacet.pooledRemoveCollateral.selector;
        s[4] = IILMPooledFacet.pooledBorrow.selector;
        s[5] = IILMPooledFacet.pooledRepay.selector;
    }

    function _selectorsPooledLiquidation() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IILMPooledLiquidationFacet.pooledLiquidationCall.selector;
    }

    function _selectorsPooledView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IILMPooledViewFacet.getPooledMarket.selector;
        s[1] = IILMPooledViewFacet.getPooledPosition.selector;
        s[2] = IILMPooledViewFacet.previewHealthFactor.selector;
        s[3] = IILMPooledViewFacet.previewSupplyBalance.selector;
        s[4] = IILMPooledViewFacet.previewDebtBalance.selector;
        s[5] = IILMPooledViewFacet.getPooledMarketProtocolFeeAssets.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = IILMTestHarness.setPositionNftRaw.selector;
        s[1] = IILMTestHarness.seedPool.selector;
        s[2] = IILMTestHarness.setPoolPrincipal.selector;
        s[3] = IILMTestHarness.setPoolTotalsAndTracked.selector;
        s[4] = IILMTestHarness.setGlobalFeeSplits.selector;
        s[5] = IILMTestHarness.setTreasury.selector;
        s[6] = IILMTestHarness.setModuleAciPausedRaw.selector;
        s[7] = IILMTestHarness.getPoolPrincipal.selector;
        s[8] = IILMTestHarness.getEncumberedForModule.selector;
        s[9] = IILMTestHarness.getPoolActiveCreditPrincipalTotal.selector;
        s[10] = IILMTestHarness.getPoolUserActiveCreditEncumbrancePrincipal.selector;
        s[11] = IILMTestHarness.getModuleAciPausedRaw.selector;
        s[12] = IILMTestHarness.getAvailablePrincipal.selector;
    }
}

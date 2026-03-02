// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import {ILMIsolatedLiquidationFacet} from "../../src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import {IlmManagedFixedRateIrm} from "../../src/ilm-isolated/irm/IlmManagedFixedRateIrm.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ModuleAumOutOfBounds} from "../../src/libraries/Errors.sol";

interface IPoolManagementILMEcon {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

interface IPositionManagementILMEcon {
    function mintPositionWithDeposit(uint256 pid, uint256 amount, uint256 maxAmount, uint256 maxFee)
        external
        payable
        returns (uint256 tokenId);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount, uint256 maxAmount) external payable;
}

interface IModuleRegistryILMEcon {
    function registerModule(bytes32 metadataHash) external payable returns (uint256 moduleId);
    function setModuleAumBounds(uint16 minBps, uint16 maxBps) external;
    function setModuleAumBps(uint256 moduleId, uint16 bps) external;
}

interface IModuleGatewayILMEcon {
    function pokeModuleAum(uint256 positionId, uint256 poolId, uint256 moduleId) external;
}

interface IAdminGovernanceILMEcon {
    function setTreasury(address treasury) external;
    function setTreasuryShareBps(uint16 shareBps) external;
    function setActiveCreditShareBps(uint16 shareBps) external;
    function setActionFeeBounds(uint128 minAmount, uint128 maxAmount) external;
    function setActionFeeConfig(uint256 pid, bytes32 action, uint128 amount, bool enabled) external;
}

interface IILMIsolatedAdminILMEcon {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function setMaxStaleness(uint256 maxStaleness) external;
    function setFee(bytes32 marketId, uint256 fee) external;
    function setMarketLiquidationFeeBps(bytes32 marketId, uint16 bps) external;
    function createIlmIsolatedMarket(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params, uint256 moduleId)
        external
        returns (bytes32 marketId);
}

interface IILMIsolatedILMEcon {
    function isolatedSupply(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
    function isolatedWithdraw(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
    function isolatedSupplyCollateral(bytes32 marketId, uint256 assets, uint256 positionId) external;
    function isolatedWithdrawCollateral(bytes32 marketId, uint256 assets, uint256 positionId) external;
    function isolatedBorrow(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
    function isolatedRepay(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
}

interface IILMIsolatedLiquidationILMEcon {
    function isolatedLiquidate(
        bytes32 marketId,
        uint256 borrowerPositionId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 liquidatorPositionId
    ) external returns (uint256 seizedOut, uint256 repaidAssetsOut);
}

interface IILMIsolatedViewILMEcon {
    function getIsolatedMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory market);
    function getIsolatedPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory position);
}

contract ILMIsolatedEconomicHarnessFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setIlmOwner(address owner_) external {
        LibIlmIsolatedStorage.s().owner = owner_;
    }

    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function getPoolFeeIndex(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].feeIndex;
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }
}

interface IILMIsolatedEconomicHarness {
    function setPositionNftRaw(address nft, bool enabled) external;
    function setIlmOwner(address owner_) external;
    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256);
    function getPoolFeeIndex(uint256 poolId) external view returns (uint256);
    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256);
}

contract MutableOracleAdapter is IIlmIsolatedOracleAdapter {
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

contract ILMIsolatedEconomicControlsTest is Test {
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");

    uint256 internal constant LOAN_POOL_ID = 41_001;
    uint256 internal constant COLLATERAL_POOL_ID = 41_002;

    address internal constant LENDER = address(0xA11CE);
    address internal constant LOOPER = address(0xB0B);
    address internal constant CONSERVATIVE = address(0xCAFE);
    address internal constant LIQUIDATOR = address(0xD00D);
    address internal constant TREASURY = address(0xFEE1);

    Diamond internal diamond;
    PositionNFT internal nft;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;

    IPoolManagementILMEcon internal poolFacet;
    IPositionManagementILMEcon internal positionFacet;
    IModuleRegistryILMEcon internal moduleRegistry;
    IModuleGatewayILMEcon internal moduleGateway;
    IAdminGovernanceILMEcon internal governance;
    IILMIsolatedAdminILMEcon internal ilmAdmin;
    IILMIsolatedILMEcon internal ilm;
    IILMIsolatedLiquidationILMEcon internal ilmLiquidation;
    IILMIsolatedViewILMEcon internal ilmView;
    IILMIsolatedEconomicHarness internal harness;

    MutableOracleAdapter internal oracle;
    IlmManagedFixedRateIrm internal zeroRateIrm;
    IlmManagedFixedRateIrm internal highRateIrm;

    struct AdversarialState {
        bytes32 marketId;
        uint256 moduleId;
        uint256 aggressivePositionId;
        uint256 conservativePositionId;
        uint256 liquidatorPositionId;
        bytes32 aggressiveKey;
        bytes32 conservativeKey;
        bytes32 liquidatorKey;
        int256 aggressiveStart;
        int256 conservativeStart;
        int256 liquidatorStart;
        uint256 treasuryLoanBefore;
        uint256 treasuryCollateralBefore;
        uint256 loanFeeIndexBefore;
        uint256 collateralFeeIndexBefore;
    }

    function setUp() public {
        _deployDiamond();
        _wireInterfaces();

        loanToken = new MockERC20("Loan", "LOAN", 18, 0);
        collateralToken = new MockERC20("Collateral", "COLL", 18, 0);

        nft = new PositionNFT();
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));
        harness.setPositionNftRaw(address(nft), true);
        harness.setIlmOwner(address(this));

        poolFacet.initPool(LOAN_POOL_ID, address(loanToken), _poolConfig());
        poolFacet.initPool(COLLATERAL_POOL_ID, address(collateralToken), _poolConfig());

        governance.setTreasury(TREASURY);
        governance.setTreasuryShareBps(2_000);
        governance.setActiveCreditShareBps(0);

        governance.setActionFeeBounds(1e15, 1_000e18);

        oracle = new MutableOracleAdapter();
        oracle.setPrice(IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        zeroRateIrm = new IlmManagedFixedRateIrm(0);
        highRateIrm = new IlmManagedFixedRateIrm(31_709_791_983); // ~100% APR.

        _seedBalancesAndApprovals();
    }

    function test_sameAssetLoopInvariant_nonPositiveCarryAfterLongHorizon() public {
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_BORROW, 5e18, true);
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_REPAY, 5e18, true);

        moduleRegistry.setModuleAumBounds(0, 1_000);
        uint256 moduleId = moduleRegistry.registerModule(keccak256("ILM_LOOP_MODULE"));
        moduleRegistry.setModuleAumBps(moduleId, 300);

        ilmAdmin.enableIrm(address(zeroRateIrm));
        ilmAdmin.enableLltv(95e16);
        ilmAdmin.setMaxStaleness(365 days);

        bytes32 marketId = ilmAdmin.createIlmIsolatedMarket(
            IlmIsolatedTypes.IlmIsolatedMarketParams({
                loanPoolId: LOAN_POOL_ID,
                collateralPoolId: LOAN_POOL_ID,
                oracle: address(oracle),
                irm: address(zeroRateIrm),
                lltv: 95e16
            }),
            moduleId
        );

        uint256 lenderPositionId = _mintWithLoanDeposit(LENDER, 8_000_000e18);
        uint256 looperPositionId = _mintWithLoanDeposit(LOOPER, 3_000_000e18);
        bytes32 looperKey = nft.getPositionKey(looperPositionId);

        vm.prank(LENDER);
        ilm.isolatedSupply(marketId, 7_000_000e18, 0, lenderPositionId);

        vm.startPrank(LOOPER);
        ilm.isolatedSupplyCollateral(marketId, 1_000_000e18, looperPositionId);
        ilm.isolatedBorrow(marketId, 800_000e18, 0, looperPositionId);
        ilm.isolatedSupplyCollateral(marketId, 600_000e18, looperPositionId);
        ilm.isolatedBorrow(marketId, 400_000e18, 0, looperPositionId);
        vm.stopPrank();

        int256 startNet = _netLoanValueSameAsset(marketId, looperKey);
        uint256 treasuryBefore = loanToken.balanceOf(TREASURY);

        for (uint256 day = 0; day < 365; day++) {
            vm.warp(block.timestamp + 1 days);
            moduleGateway.pokeModuleAum(looperPositionId, LOAN_POOL_ID, moduleId);

            if ((day + 1) % 30 == 0) {
                vm.startPrank(LOOPER);
                ilm.isolatedBorrow(marketId, 20_000e18, 0, looperPositionId);
                ilm.isolatedRepay(marketId, 20_000e18, 0, looperPositionId);
                vm.stopPrank();
            }
        }

        IlmIsolatedTypes.IlmIsolatedPosition memory position = ilmView.getIsolatedPosition(marketId, looperKey);
        vm.startPrank(LOOPER);
        if (position.borrowShares > 0) {
            ilm.isolatedRepay(marketId, 0, uint256(position.borrowShares), looperPositionId);
        }
        position = ilmView.getIsolatedPosition(marketId, looperKey);
        if (position.collateralAssets > 0) {
            ilm.isolatedWithdrawCollateral(marketId, uint256(position.collateralAssets), looperPositionId);
        }
        vm.stopPrank();

        int256 endNet = _netLoanValueSameAsset(marketId, looperKey);
        assertLe(endNet, startNet, "same-asset loop carry must be non-positive across long horizon");

        uint256 treasuryAfter = loanToken.balanceOf(TREASURY);
        assertGt(treasuryAfter - treasuryBefore, 0, "treasury must receive routed fees");
    }

    function test_governanceBounds_strictActionFeesAndModuleAum() public {
        governance.setActionFeeBounds(10e18, 100e18);

        vm.expectRevert("EqualFi: fee out of bounds");
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_BORROW, 9e18, true);
        vm.expectRevert("EqualFi: fee out of bounds");
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_REPAY, 101e18, true);
        vm.expectRevert("EqualFi: fee out of bounds");
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_WITHDRAW, 101e18, true);

        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_BORROW, 10e18, true);
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_REPAY, 55e18, true);
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_WITHDRAW, 100e18, true);

        moduleRegistry.setModuleAumBounds(50, 250);
        uint256 moduleId = moduleRegistry.registerModule(keccak256("ILM_AUM_BOUNDS"));

        vm.expectRevert(abi.encodeWithSelector(ModuleAumOutOfBounds.selector, uint16(49), uint16(50), uint16(250)));
        moduleRegistry.setModuleAumBps(moduleId, 49);
        vm.expectRevert(abi.encodeWithSelector(ModuleAumOutOfBounds.selector, uint16(251), uint16(50), uint16(250)));
        moduleRegistry.setModuleAumBps(moduleId, 251);

        moduleRegistry.setModuleAumBps(moduleId, 50);
        moduleRegistry.setModuleAumBps(moduleId, 250);
    }

    function test_adversarialLongHorizonSimulation_quantifiesWorstCasePnl() public {
        AdversarialState memory st = _setupAdversarialState();
        for (uint256 day = 0; day < 180; day++) {
            vm.warp(block.timestamp + 1 days);
            moduleGateway.pokeModuleAum(st.aggressivePositionId, COLLATERAL_POOL_ID, st.moduleId);
            moduleGateway.pokeModuleAum(st.conservativePositionId, COLLATERAL_POOL_ID, st.moduleId);

            if ((day + 1) % 30 == 0) {
                vm.prank(LOOPER);
                // Adversarial cadence attempts to relever; if health no longer permits, continue simulation.
                (bool ok,) = address(ilm).call(
                    abi.encodeWithSelector(
                        IILMIsolatedILMEcon.isolatedBorrow.selector, st.marketId, 50_000e18, 0, st.aggressivePositionId
                    )
                );
                ok;
            }

            if (day == 120) {
                oracle.setPrice(900 * IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);
                vm.prank(LIQUIDATOR);
                (bool liqOk,) = address(ilmLiquidation).call(
                    abi.encodeWithSelector(
                        IILMIsolatedLiquidationILMEcon.isolatedLiquidate.selector,
                        st.marketId,
                        st.aggressivePositionId,
                        120e18,
                        0,
                        st.liquidatorPositionId
                    )
                );
                assertTrue(liqOk, "liquidation shock must execute");
            }
        }

        _fullyRepayAndWithdrawCollateral(st.marketId, st.aggressivePositionId, LOOPER);
        _fullyRepayAndWithdrawCollateral(st.marketId, st.conservativePositionId, CONSERVATIVE);

        int256 aggressiveEnd = _netLoanValueCrossAsset(st.marketId, st.aggressiveKey, 900 * IlmIsolatedTypes.ORACLE_PRICE_SCALE);
        int256 conservativeEnd =
            _netLoanValueCrossAsset(st.marketId, st.conservativeKey, 900 * IlmIsolatedTypes.ORACLE_PRICE_SCALE);
        int256 liquidatorEnd =
            _netLoanValueCrossAsset(st.marketId, st.liquidatorKey, 900 * IlmIsolatedTypes.ORACLE_PRICE_SCALE);

        int256 aggressivePnl = aggressiveEnd - st.aggressiveStart;
        int256 conservativePnl = conservativeEnd - st.conservativeStart;
        int256 liquidatorPnl = liquidatorEnd - st.liquidatorStart;

        int256 worstPnl = _minInt(aggressivePnl, _minInt(conservativePnl, liquidatorPnl));
        assertEq(worstPnl, aggressivePnl, "aggressive loop should be worst-case under liquidation shock");

        uint256 treasuryLoanDelta = loanToken.balanceOf(TREASURY) - st.treasuryLoanBefore;
        uint256 treasuryCollateralDelta = collateralToken.balanceOf(TREASURY) - st.treasuryCollateralBefore;
        assertGt(treasuryLoanDelta + treasuryCollateralDelta, 0, "treasury revenue must be positive");

        uint256 loanFeeIndexAfter = harness.getPoolFeeIndex(LOAN_POOL_ID);
        uint256 collateralFeeIndexAfter = harness.getPoolFeeIndex(COLLATERAL_POOL_ID);
        assertTrue(
            loanFeeIndexAfter > st.loanFeeIndexBefore || collateralFeeIndexAfter > st.collateralFeeIndexBefore,
            "fee index must capture routed flow"
        );

        emit log_named_int("aggressive_pnl_loan_units", aggressivePnl);
        emit log_named_int("conservative_pnl_loan_units", conservativePnl);
        emit log_named_int("liquidator_pnl_loan_units", liquidatorPnl);
        emit log_named_int("worst_case_pnl_loan_units", worstPnl);
    }

    function _setupAdversarialState() internal returns (AdversarialState memory st) {
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_BORROW, 3e18, true);
        governance.setActionFeeConfig(LOAN_POOL_ID, ACTION_REPAY, 3e18, true);

        moduleRegistry.setModuleAumBounds(0, 1_000);
        st.moduleId = moduleRegistry.registerModule(keccak256("ILM_ADVERSARIAL_MODULE"));
        moduleRegistry.setModuleAumBps(st.moduleId, 200);

        ilmAdmin.enableIrm(address(highRateIrm));
        ilmAdmin.enableLltv(75e16);
        ilmAdmin.setMaxStaleness(365 days);

        oracle.setPrice(2_000 * IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);
        st.marketId = ilmAdmin.createIlmIsolatedMarket(
            IlmIsolatedTypes.IlmIsolatedMarketParams({
                loanPoolId: LOAN_POOL_ID,
                collateralPoolId: COLLATERAL_POOL_ID,
                oracle: address(oracle),
                irm: address(highRateIrm),
                lltv: 75e16
            }),
            st.moduleId
        );
        ilmAdmin.setFee(st.marketId, 10e16);
        ilmAdmin.setMarketLiquidationFeeBps(st.marketId, 500);

        uint256 lenderPositionId = _mintWithLoanDeposit(LENDER, 8_000_000e18);
        st.aggressivePositionId = _mintWithLoanDeposit(LOOPER, 800_000e18);
        st.conservativePositionId = _mintWithLoanDeposit(CONSERVATIVE, 500_000e18);
        st.liquidatorPositionId = _mintWithLoanDeposit(LIQUIDATOR, 2_000_000e18);

        _depositCollateral(st.aggressivePositionId, 1_000e18, LOOPER);
        _depositCollateral(st.conservativePositionId, 1_000e18, CONSERVATIVE);

        vm.prank(LENDER);
        ilm.isolatedSupply(st.marketId, 7_000_000e18, 0, lenderPositionId);

        vm.startPrank(LOOPER);
        ilm.isolatedSupplyCollateral(st.marketId, 800e18, st.aggressivePositionId);
        ilm.isolatedBorrow(st.marketId, 1_000_000e18, 0, st.aggressivePositionId);
        vm.stopPrank();

        vm.startPrank(CONSERVATIVE);
        ilm.isolatedSupplyCollateral(st.marketId, 500e18, st.conservativePositionId);
        ilm.isolatedBorrow(st.marketId, 300_000e18, 0, st.conservativePositionId);
        vm.stopPrank();

        st.aggressiveKey = nft.getPositionKey(st.aggressivePositionId);
        st.conservativeKey = nft.getPositionKey(st.conservativePositionId);
        st.liquidatorKey = nft.getPositionKey(st.liquidatorPositionId);

        uint256 price = 2_000 * IlmIsolatedTypes.ORACLE_PRICE_SCALE;
        st.aggressiveStart = _netLoanValueCrossAsset(st.marketId, st.aggressiveKey, price);
        st.conservativeStart = _netLoanValueCrossAsset(st.marketId, st.conservativeKey, price);
        st.liquidatorStart = _netLoanValueCrossAsset(st.marketId, st.liquidatorKey, price);

        st.treasuryLoanBefore = loanToken.balanceOf(TREASURY);
        st.treasuryCollateralBefore = collateralToken.balanceOf(TREASURY);
        st.loanFeeIndexBefore = harness.getPoolFeeIndex(LOAN_POOL_ID);
        st.collateralFeeIndexBefore = harness.getPoolFeeIndex(COLLATERAL_POOL_ID);
    }

    function _fullyRepayAndWithdrawCollateral(bytes32 marketId, uint256 positionId, address owner) internal {
        bytes32 key = nft.getPositionKey(positionId);
        IlmIsolatedTypes.IlmIsolatedPosition memory position = ilmView.getIsolatedPosition(marketId, key);

        vm.startPrank(owner);
        if (position.borrowShares > 0) {
            ilm.isolatedRepay(marketId, 0, uint256(position.borrowShares), positionId);
        }

        position = ilmView.getIsolatedPosition(marketId, key);
        if (position.collateralAssets > 0) {
            ilm.isolatedWithdrawCollateral(marketId, uint256(position.collateralAssets), positionId);
        }
        vm.stopPrank();
    }

    function _netLoanValueSameAsset(bytes32 marketId, bytes32 positionKey) internal view returns (int256) {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = ilmView.getIsolatedMarket(marketId);
        IlmIsolatedTypes.IlmIsolatedPosition memory position = ilmView.getIsolatedPosition(marketId, positionKey);

        uint256 principal = harness.getPoolPrincipal(LOAN_POOL_ID, positionKey);
        uint256 debtAssets =
            LibIlmSharesMath.toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);

        return int256(principal) - int256(debtAssets);
    }

    function _netLoanValueCrossAsset(bytes32 marketId, bytes32 positionKey, uint256 price) internal view returns (int256) {
        IlmIsolatedTypes.IlmIsolatedMarket memory market = ilmView.getIsolatedMarket(marketId);
        IlmIsolatedTypes.IlmIsolatedPosition memory position = ilmView.getIsolatedPosition(marketId, positionKey);

        uint256 principalLoan = harness.getPoolPrincipal(LOAN_POOL_ID, positionKey);
        uint256 principalCollateral = harness.getPoolPrincipal(COLLATERAL_POOL_ID, positionKey);
        uint256 collateralAsLoan =
            (principalCollateral * price) / IlmIsolatedTypes.ORACLE_PRICE_SCALE;
        uint256 debtAssets =
            LibIlmSharesMath.toAssetsUp(position.borrowShares, market.totalBorrowAssets, market.totalBorrowShares);

        return int256(principalLoan + collateralAsLoan) - int256(debtAssets);
    }

    function _seedBalancesAndApprovals() internal {
        loanToken.mint(LENDER, 20_000_000e18);
        loanToken.mint(LOOPER, 20_000_000e18);
        loanToken.mint(CONSERVATIVE, 20_000_000e18);
        loanToken.mint(LIQUIDATOR, 20_000_000e18);

        collateralToken.mint(LOOPER, 10_000e18);
        collateralToken.mint(CONSERVATIVE, 10_000e18);

        vm.prank(LENDER);
        IERC20(address(loanToken)).approve(address(diamond), type(uint256).max);
        vm.prank(LOOPER);
        IERC20(address(loanToken)).approve(address(diamond), type(uint256).max);
        vm.prank(CONSERVATIVE);
        IERC20(address(loanToken)).approve(address(diamond), type(uint256).max);
        vm.prank(LIQUIDATOR);
        IERC20(address(loanToken)).approve(address(diamond), type(uint256).max);

        vm.prank(LOOPER);
        IERC20(address(collateralToken)).approve(address(diamond), type(uint256).max);
        vm.prank(CONSERVATIVE);
        IERC20(address(collateralToken)).approve(address(diamond), type(uint256).max);
    }

    function _mintWithLoanDeposit(address user, uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(user);
        tokenId = positionFacet.mintPositionWithDeposit(LOAN_POOL_ID, amount, amount, 0);
    }

    function _depositCollateral(uint256 tokenId, uint256 amount, address user) internal {
        vm.prank(user);
        positionFacet.depositToPosition(tokenId, COLLATERAL_POOL_ID, amount, amount);
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 0;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 0;
        cfg.flashLoanFeeBps = 0;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 1_000;
        cfg.fixedTermConfigs = new Types.FixedTermConfig[](0);
    }

    function _deployDiamond() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        PoolManagementFacet poolManagementFacet = new PoolManagementFacet();
        PositionManagementFacet positionManagementFacet = new PositionManagementFacet();
        ModuleRegistryFacet moduleRegistryFacet = new ModuleRegistryFacet();
        ModuleGatewayFacet moduleGatewayFacet = new ModuleGatewayFacet();
        AdminGovernanceFacet governanceFacet = new AdminGovernanceFacet();
        ILMIsolatedAdminFacet ilmAdminFacet = new ILMIsolatedAdminFacet();
        ILMIsolatedFacet ilmFacet = new ILMIsolatedFacet();
        ILMIsolatedLiquidationFacet ilmLiqFacet = new ILMIsolatedLiquidationFacet();
        ILMIsolatedViewFacet ilmViewFacet = new ILMIsolatedViewFacet();
        ILMIsolatedEconomicHarnessFacet harnessFacet = new ILMIsolatedEconomicHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](11);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(poolManagementFacet), _selectorsPoolManagement());
        cuts[2] = _cut(address(positionManagementFacet), _selectorsPositionManagement());
        cuts[3] = _cut(address(moduleRegistryFacet), _selectorsModuleRegistry());
        cuts[4] = _cut(address(moduleGatewayFacet), _selectorsModuleGateway());
        cuts[5] = _cut(address(governanceFacet), _selectorsGovernance());
        cuts[6] = _cut(address(ilmAdminFacet), _selectorsIlmAdmin());
        cuts[7] = _cut(address(ilmFacet), _selectorsIlm());
        cuts[8] = _cut(address(ilmLiqFacet), _selectorsIlmLiquidation());
        cuts[9] = _cut(address(ilmViewFacet), _selectorsIlmView());
        cuts[10] = _cut(address(harnessFacet), _selectorsHarness());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
    }

    function _wireInterfaces() internal {
        poolFacet = IPoolManagementILMEcon(address(diamond));
        positionFacet = IPositionManagementILMEcon(address(diamond));
        moduleRegistry = IModuleRegistryILMEcon(address(diamond));
        moduleGateway = IModuleGatewayILMEcon(address(diamond));
        governance = IAdminGovernanceILMEcon(address(diamond));
        ilmAdmin = IILMIsolatedAdminILMEcon(address(diamond));
        ilm = IILMIsolatedILMEcon(address(diamond));
        ilmLiquidation = IILMIsolatedLiquidationILMEcon(address(diamond));
        ilmView = IILMIsolatedViewILMEcon(address(diamond));
        harness = IILMIsolatedEconomicHarness(address(diamond));
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

    function _selectorsPoolManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IPoolManagementILMEcon.initPool.selector;
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IPositionManagementILMEcon.mintPositionWithDeposit.selector;
        s[1] = IPositionManagementILMEcon.depositToPosition.selector;
    }

    function _selectorsModuleRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = IModuleRegistryILMEcon.registerModule.selector;
        s[1] = IModuleRegistryILMEcon.setModuleAumBounds.selector;
        s[2] = IModuleRegistryILMEcon.setModuleAumBps.selector;
    }

    function _selectorsModuleGateway() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IModuleGatewayILMEcon.pokeModuleAum.selector;
    }

    function _selectorsGovernance() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IAdminGovernanceILMEcon.setTreasury.selector;
        s[1] = IAdminGovernanceILMEcon.setTreasuryShareBps.selector;
        s[2] = IAdminGovernanceILMEcon.setActiveCreditShareBps.selector;
        s[3] = IAdminGovernanceILMEcon.setActionFeeBounds.selector;
        s[4] = IAdminGovernanceILMEcon.setActionFeeConfig.selector;
    }

    function _selectorsIlmAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IILMIsolatedAdminILMEcon.enableIrm.selector;
        s[1] = IILMIsolatedAdminILMEcon.enableLltv.selector;
        s[2] = IILMIsolatedAdminILMEcon.setMaxStaleness.selector;
        s[3] = IILMIsolatedAdminILMEcon.setFee.selector;
        s[4] = IILMIsolatedAdminILMEcon.setMarketLiquidationFeeBps.selector;
        s[5] = IILMIsolatedAdminILMEcon.createIlmIsolatedMarket.selector;
    }

    function _selectorsIlm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IILMIsolatedILMEcon.isolatedSupply.selector;
        s[1] = IILMIsolatedILMEcon.isolatedWithdraw.selector;
        s[2] = IILMIsolatedILMEcon.isolatedSupplyCollateral.selector;
        s[3] = IILMIsolatedILMEcon.isolatedWithdrawCollateral.selector;
        s[4] = IILMIsolatedILMEcon.isolatedBorrow.selector;
        s[5] = IILMIsolatedILMEcon.isolatedRepay.selector;
    }

    function _selectorsIlmLiquidation() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IILMIsolatedLiquidationILMEcon.isolatedLiquidate.selector;
    }

    function _selectorsIlmView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IILMIsolatedViewILMEcon.getIsolatedMarket.selector;
        s[1] = IILMIsolatedViewILMEcon.getIsolatedPosition.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IILMIsolatedEconomicHarness.setPositionNftRaw.selector;
        s[1] = IILMIsolatedEconomicHarness.setIlmOwner.selector;
        s[2] = IILMIsolatedEconomicHarness.getPoolPrincipal.selector;
        s[3] = IILMIsolatedEconomicHarness.getPoolFeeIndex.selector;
        s[4] = IILMIsolatedEconomicHarness.getPoolTrackedBalance.selector;
    }

    function _minInt(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import {ILMIsolatedLiquidationFacet} from "../../src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import {IlmManagedFixedRateIrm} from "../../src/ilm-isolated/irm/IlmManagedFixedRateIrm.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

interface IPoolManagementFork {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

interface IPositionManagementFork {
    function mintPositionWithDeposit(uint256 pid, uint256 amount, uint256 maxAmount, uint256 maxFee)
        external
        payable
        returns (uint256 tokenId);
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 principalToWithdraw, uint256 minReceived)
        external
        payable;
}

interface IModuleRegistryFork {
    function registerModule(bytes32 metadataHash) external payable returns (uint256 moduleId);
}

interface IILMIsolatedAdminFork {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function setMaxStaleness(uint256 maxStaleness) external;
    function createIlmIsolatedMarket(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params, uint256 moduleId)
        external
        returns (bytes32 marketId);
}

interface IILMIsolatedFork {
    function isolatedSupply(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
    function isolatedSupplyCollateral(bytes32 marketId, uint256 assets, uint256 positionId) external;
    function isolatedBorrow(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
}

interface IILMIsolatedLiquidationFork {
    function isolatedLiquidate(
        bytes32 marketId,
        uint256 borrowerPositionId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 liquidatorPositionId
    ) external returns (uint256 seizedOut, uint256 repaidAssetsOut);
}

interface IILMIsolatedViewFork {
    function getIsolatedMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory market);
    function getIsolatedPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory position);
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

contract MainnetEthUsdcChainlinkOracleAdapter is IIlmIsolatedOracleAdapter {
    error ChainlinkInvalidAnswer();

    IChainlinkAggregator public immutable ethUsdFeed;
    IChainlinkAggregator public immutable usdcUsdFeed;
    uint256 public immutable numeratorScale;
    uint256 public immutable denominatorScale;

    constructor(address ethUsdFeed_, address usdcUsdFeed_) {
        ethUsdFeed = IChainlinkAggregator(ethUsdFeed_);
        usdcUsdFeed = IChainlinkAggregator(usdcUsdFeed_);
        numeratorScale = 10 ** (uint256(usdcUsdFeed.decimals()) + 24);
        denominatorScale = 10 ** uint256(ethUsdFeed.decimals());
    }

    function getIsolatedPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        (, int256 ethUsd,, uint256 ethUpdatedAt,) = ethUsdFeed.latestRoundData();
        (, int256 usdcUsd,, uint256 usdcUpdatedAt,) = usdcUsdFeed.latestRoundData();
        if (ethUsd <= 0 || usdcUsd <= 0) revert ChainlinkInvalidAnswer();

        price = Math.mulDiv(uint256(ethUsd), numeratorScale, uint256(usdcUsd) * denominatorScale);
        updatedAt = ethUpdatedAt < usdcUpdatedAt ? ethUpdatedAt : usdcUpdatedAt;
    }
}

contract ILMIsolatedForkHarnessFacet {
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
}

interface IILMIsolatedForkHarness {
    function setPositionNftRaw(address nft, bool enabled) external;
    function setIlmOwner(address owner_) external;
    function getPoolPrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256);
}

contract ILMIsolatedForkLiquidationTest is Test {
    // Mainnet addresses.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint256 internal constant LOAN_POOL_ID = 31_001;
    uint256 internal constant COLLATERAL_POOL_ID = 31_002;
    uint256 internal constant LLTV_WAD = 75e16; // 75%

    uint256 internal constant LENDER_DEPOSIT = 2_000_000e6;
    uint256 internal constant LIQUIDATOR_DEPOSIT = 500_000e6;
    uint256 internal constant LENDER_SUPPLY = 1_500_000e6;
    uint256 internal constant BORROW_ASSETS = 1_200_000e6;
    uint256 internal constant COLLATERAL_DEPOSIT = 2 ether;
    uint256 internal constant COLLATERAL_SUPPLY = 1 ether;
    uint256 internal constant LIQUIDATION_SEIZE = 0.10 ether;

    address internal constant LENDER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B);
    address internal constant LIQUIDATOR = address(0xCAFE);

    Diamond internal diamond;
    PositionNFT internal nft;
    IlmManagedFixedRateIrm internal irm;
    MainnetEthUsdcChainlinkOracleAdapter internal chainlinkOracle;

    IPoolManagementFork internal poolFacet;
    IPositionManagementFork internal positionFacet;
    IModuleRegistryFork internal moduleRegistry;
    IILMIsolatedAdminFork internal ilmAdmin;
    IILMIsolatedFork internal ilm;
    IILMIsolatedLiquidationFork internal ilmLiquidation;
    IILMIsolatedViewFork internal ilmView;
    IILMIsolatedForkHarness internal harness;

    bool internal forkReady;
    bytes32 internal marketId;
    uint256 internal lenderPositionId;
    uint256 internal borrowerPositionId;
    uint256 internal liquidatorPositionId;
    bytes32 internal borrowerKey;
    bytes32 internal liquidatorKey;

    function setUp() public {
        if (!_selectFork()) {
            return;
        }
        if (USDC.code.length == 0 || ETH_USD_FEED.code.length == 0 || USDC_USD_FEED.code.length == 0) {
            return;
        }

        _deployDiamond();
        _wireInterfaces();
        _deployAndConfigureProtocol();
        _seedRealPoolsAndMarket();
        forkReady = true;
    }

    function testFork_realEthUsdcChainlink_liquidationFlow() public {
        if (!forkReady) {
            return;
        }

        (uint256 oraclePrice, uint256 updatedAt) = chainlinkOracle.getIsolatedPrice(address(chainlinkOracle));
        assertGt(oraclePrice, 0, "oracle price must be non-zero");
        assertGt(updatedAt, 0, "oracle update timestamp must be non-zero");

        IlmIsolatedTypes.IlmIsolatedPosition memory borrowerBefore = ilmView.getIsolatedPosition(marketId, borrowerKey);
        uint256 liquidatorLoanPrincipalBefore = harness.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey);
        uint256 liquidatorCollateralPrincipalBefore = harness.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);

        vm.warp(block.timestamp + 120 days);

        vm.prank(LIQUIDATOR);
        (uint256 seizedOut, uint256 repaidAssetsOut) =
            ilmLiquidation.isolatedLiquidate(marketId, borrowerPositionId, LIQUIDATION_SEIZE, 0, liquidatorPositionId);

        IlmIsolatedTypes.IlmIsolatedPosition memory borrowerAfter = ilmView.getIsolatedPosition(marketId, borrowerKey);
        uint256 liquidatorLoanPrincipalAfter = harness.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey);
        uint256 liquidatorCollateralPrincipalAfter = harness.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey);

        assertLt(uint256(borrowerAfter.borrowShares), uint256(borrowerBefore.borrowShares), "borrow shares must drop");
        assertLt(
            uint256(borrowerAfter.collateralAssets), uint256(borrowerBefore.collateralAssets), "collateral must be seized"
        );
        assertGt(seizedOut, 0, "liquidator must seize collateral");
        assertGt(repaidAssetsOut, 0, "liquidator must repay debt");
        assertEq(liquidatorLoanPrincipalBefore - liquidatorLoanPrincipalAfter, repaidAssetsOut, "loan principal debited");
        assertEq(
            liquidatorCollateralPrincipalAfter - liquidatorCollateralPrincipalBefore,
            seizedOut,
            "collateral principal credited"
        );
    }

    function _deployDiamond() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        PoolManagementFacet poolManagementFacet = new PoolManagementFacet();
        PositionManagementFacet positionManagementFacet = new PositionManagementFacet();
        ModuleRegistryFacet moduleRegistryFacet = new ModuleRegistryFacet();
        ILMIsolatedAdminFacet ilmAdminFacet = new ILMIsolatedAdminFacet();
        ILMIsolatedFacet ilmFacet = new ILMIsolatedFacet();
        ILMIsolatedLiquidationFacet ilmLiqFacet = new ILMIsolatedLiquidationFacet();
        ILMIsolatedViewFacet ilmViewFacet = new ILMIsolatedViewFacet();
        ILMIsolatedForkHarnessFacet harnessFacet = new ILMIsolatedForkHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](9);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(poolManagementFacet), _selectorsPoolManagement());
        cuts[2] = _cut(address(positionManagementFacet), _selectorsPositionManagement());
        cuts[3] = _cut(address(moduleRegistryFacet), _selectorsModuleRegistry());
        cuts[4] = _cut(address(ilmAdminFacet), _selectorsIlmAdmin());
        cuts[5] = _cut(address(ilmFacet), _selectorsIlm());
        cuts[6] = _cut(address(ilmLiqFacet), _selectorsIlmLiquidation());
        cuts[7] = _cut(address(ilmViewFacet), _selectorsIlmView());
        cuts[8] = _cut(address(harnessFacet), _selectorsHarness());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
    }

    function _wireInterfaces() internal {
        poolFacet = IPoolManagementFork(address(diamond));
        positionFacet = IPositionManagementFork(address(diamond));
        moduleRegistry = IModuleRegistryFork(address(diamond));
        ilmAdmin = IILMIsolatedAdminFork(address(diamond));
        ilm = IILMIsolatedFork(address(diamond));
        ilmLiquidation = IILMIsolatedLiquidationFork(address(diamond));
        ilmView = IILMIsolatedViewFork(address(diamond));
        harness = IILMIsolatedForkHarness(address(diamond));
    }

    function _deployAndConfigureProtocol() internal {
        nft = new PositionNFT();
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));
        harness.setPositionNftRaw(address(nft), true);
        harness.setIlmOwner(address(this));

        irm = new IlmManagedFixedRateIrm(32_000_000_000); // ~101% APR.
        chainlinkOracle = new MainnetEthUsdcChainlinkOracleAdapter(ETH_USD_FEED, USDC_USD_FEED);

        poolFacet.initPool(LOAN_POOL_ID, USDC, _defaultPoolConfig());
        poolFacet.initPool(COLLATERAL_POOL_ID, address(0), _defaultPoolConfig());

        ilmAdmin.enableIrm(address(irm));
        ilmAdmin.enableLltv(LLTV_WAD);
        ilmAdmin.setMaxStaleness(7 days);
    }

    function _seedRealPoolsAndMarket() internal {
        uint256 moduleId = moduleRegistry.registerModule(keccak256("ILM_ISOLATED_MAINNET_FORK"));
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: LOAN_POOL_ID,
            collateralPoolId: COLLATERAL_POOL_ID,
            oracle: address(chainlinkOracle),
            irm: address(irm),
            lltv: LLTV_WAD
        });
        marketId = ilmAdmin.createIlmIsolatedMarket(params, moduleId);

        deal(USDC, LENDER, LENDER_DEPOSIT);
        deal(USDC, LIQUIDATOR, LIQUIDATOR_DEPOSIT);

        vm.startPrank(LENDER);
        IERC20(USDC).approve(address(diamond), type(uint256).max);
        lenderPositionId = positionFacet.mintPositionWithDeposit(LOAN_POOL_ID, LENDER_DEPOSIT, LENDER_DEPOSIT, 0);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        IERC20(USDC).approve(address(diamond), type(uint256).max);
        liquidatorPositionId =
            positionFacet.mintPositionWithDeposit(LOAN_POOL_ID, LIQUIDATOR_DEPOSIT, LIQUIDATOR_DEPOSIT, 0);
        vm.stopPrank();
        liquidatorKey = nft.getPositionKey(liquidatorPositionId);

        vm.prank(BORROWER);
        borrowerPositionId =
            positionFacet.mintPositionWithDeposit{value: COLLATERAL_DEPOSIT}(COLLATERAL_POOL_ID, COLLATERAL_DEPOSIT, COLLATERAL_DEPOSIT, 0);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        vm.prank(LENDER);
        ilm.isolatedSupply(marketId, LENDER_SUPPLY, 0, lenderPositionId);

        vm.prank(BORROWER);
        ilm.isolatedSupplyCollateral(marketId, COLLATERAL_SUPPLY, borrowerPositionId);

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = ilm.isolatedBorrow(marketId, BORROW_ASSETS, 0, borrowerPositionId);
        assertEq(borrowedAssets, BORROW_ASSETS, "borrowed assets mismatch");

        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);
        vm.prank(BORROWER);
        positionFacet.withdrawFromPosition(borrowerPositionId, LOAN_POOL_ID, BORROW_ASSETS, 0);
        uint256 borrowerUsdcAfter = IERC20(USDC).balanceOf(BORROWER);
        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, BORROW_ASSETS, "borrower did not receive borrowed USDC");
    }

    function _defaultPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
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
        cfg.aumFeeMaxBps = 0;
        cfg.fixedTermConfigs = new Types.FixedTermConfig[](0);
    }

    function _selectFork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("RPC", string(""));
        }
        if (bytes(rpc).length == 0) {
            return false;
        }
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        uint256 forkId = blockNumber > 0 ? vm.createFork(rpc, blockNumber) : vm.createFork(rpc);
        vm.selectFork(forkId);
        return true;
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
        s[0] = IPoolManagementFork.initPool.selector;
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IPositionManagementFork.mintPositionWithDeposit.selector;
        s[1] = IPositionManagementFork.withdrawFromPosition.selector;
    }

    function _selectorsModuleRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IModuleRegistryFork.registerModule.selector;
    }

    function _selectorsIlmAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = IILMIsolatedAdminFork.enableIrm.selector;
        s[1] = IILMIsolatedAdminFork.enableLltv.selector;
        s[2] = IILMIsolatedAdminFork.setMaxStaleness.selector;
        s[3] = IILMIsolatedAdminFork.createIlmIsolatedMarket.selector;
    }

    function _selectorsIlm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = IILMIsolatedFork.isolatedSupply.selector;
        s[1] = IILMIsolatedFork.isolatedSupplyCollateral.selector;
        s[2] = IILMIsolatedFork.isolatedBorrow.selector;
    }

    function _selectorsIlmLiquidation() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IILMIsolatedLiquidationFork.isolatedLiquidate.selector;
    }

    function _selectorsIlmView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IILMIsolatedViewFork.getIsolatedMarket.selector;
        s[1] = IILMIsolatedViewFork.getIsolatedPosition.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = IILMIsolatedForkHarness.setPositionNftRaw.selector;
        s[1] = IILMIsolatedForkHarness.setIlmOwner.selector;
        s[2] = IILMIsolatedForkHarness.getPoolPrincipal.selector;
    }
}

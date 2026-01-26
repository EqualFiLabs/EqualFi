// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTestHarnessFacet} from "../equallend-direct/DirectTestHarnessFacet.sol";
import {DirectTestViewFacet} from "../equallend-direct/DirectTestViewFacet.sol";

interface IPositionManagement {
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

interface ITestHarness {
    function setPositionNFT(address nft) external;
    function setOwner(address owner) external;
    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external;
    function setPoolTotals(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external;
}

interface ITestView {
    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getTotalDebt(uint256 pid, bytes32 positionKey) external view returns (uint256);
}

interface ILending {
    function openRollingFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function makePaymentFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

interface IEqualIndexAdmin {
    function createIndex(EqualIndexBaseV3.CreateIndexParams calldata params)
        external
        payable
        returns (uint256 indexId, address token);
}

interface IEqualIndexPosition {
    function mintFromPosition(uint256 positionId, uint256 indexId, uint256 units) external returns (uint256);
    function burnFromPosition(uint256 positionId, uint256 indexId, uint256 units)
        external
        returns (uint256[] memory);
}

interface IEqualIndexActions {
    function mint(uint256 indexId, uint256 units, address to) external returns (uint256);
}

interface IAdminGovernance {
    function setDefaultPoolConfig(Types.PoolConfig calldata config) external;
    function setRollingMinPaymentBps(uint16 minPaymentBps) external;
}

interface IPoolMap {
    function setAssetToPoolId(address asset, uint256 pid) external;
}

contract PoolMapTestFacet {
    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }
}

contract EqualIndexDiamondBase is Test {
    Diamond internal diamond;
    PositionNFT internal nft;
    ITestHarness internal harness;
    ITestView internal views;

    function setUpDiamond() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _facetCut(address(cutFacet), _selectorsCut());
        cuts[1] = _facetCut(address(loupeFacet), _selectorsLoupe());
        cuts[2] = _facetCut(address(ownershipFacet), _selectorsOwnership());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        _diamondCutSingle(address(new DirectTestHarnessFacet()), _selectorsHarness());
        _diamondCutSingle(address(new DirectTestViewFacet()), _selectorsView());
        _diamondCutSingle(address(new PositionManagementFacet()), _selectorsPositionManagement());
        _diamondCutSingle(address(new LendingFacet()), _selectorsLending());
        _diamondCutSingle(address(new EqualIndexAdminFacetV3()), _selectorsIndexAdmin());
        _diamondCutSingle(address(new EqualIndexPositionFacet()), _selectorsIndexPosition());
        _diamondCutSingle(address(new EqualIndexActionsFacetV3()), _selectorsIndexActions());
        _diamondCutSingle(address(new AdminGovernanceFacet()), _selectorsAdmin());
        _diamondCutSingle(address(new PoolMapTestFacet()), _selectorsPoolMap());

        harness = ITestHarness(address(diamond));
        views = ITestView(address(diamond));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));
        harness.setOwner(address(this));
    }

    function finalizePositionNFT() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function _diamondCutSingle(address facet, bytes4[] memory selectors) internal {
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0].facetAddress = facet;
        addCuts[0].action = IDiamondCut.FacetCutAction.Add;
        addCuts[0].functionSelectors = selectors;
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _facetCut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut memory cut)
    {
        cut.facetAddress = facet;
        cut.action = IDiamondCut.FacetCutAction.Add;
        cut.functionSelectors = selectors;
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsLoupe() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectorsOwnership() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = DirectTestHarnessFacet.setPositionNFT.selector;
        s[1] = DirectTestHarnessFacet.setOwner.selector;
        s[2] = bytes4(keccak256("initPool(uint256,address,uint256,uint256,uint16)"));
        s[3] = DirectTestHarnessFacet.setPoolTotals.selector;
    }

    function _selectorsView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = DirectTestViewFacet.getUserPrincipal.selector;
        s[1] = DirectTestViewFacet.getTotalDebt.selector;
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = PositionManagementFacet.depositToPosition.selector;
    }

    function _selectorsLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = LendingFacet.openRollingFromPosition.selector;
        s[1] = LendingFacet.makePaymentFromPosition.selector;
    }

    function _selectorsIndexAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = EqualIndexAdminFacetV3.createIndex.selector;
    }

    function _selectorsIndexPosition() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualIndexPositionFacet.mintFromPosition.selector;
        s[1] = EqualIndexPositionFacet.burnFromPosition.selector;
    }

    function _selectorsIndexActions() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = EqualIndexActionsFacetV3.mint.selector;
    }

    function _selectorsAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminGovernanceFacet.setDefaultPoolConfig.selector;
        s[1] = AdminGovernanceFacet.setRollingMinPaymentBps.selector;
    }

    function _selectorsPoolMap() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = PoolMapTestFacet.setAssetToPoolId.selector;
    }
}

contract EqualIndexLeverageLoopIntegrationTest is EqualIndexDiamondBase {
    IPositionManagement internal pm;
    ILending internal lending;
    IEqualIndexAdmin internal indexAdmin;
    IEqualIndexPosition internal indexPosition;
    IEqualIndexActions internal indexActions;
    IAdminGovernance internal admin;
    IPoolMap internal poolMap;

    MockERC20 internal rETH;
    MockERC20 internal stETH;
    MockERC20 internal wstETH;

    address internal user = address(0xA11CE);

    uint256 internal positionId;
    bytes32 internal positionKey;

    uint256[] internal indexIds;
    address[] internal indexTokens;
    uint256[] internal indexPoolIds;

    uint256 internal constant POOL_RETH = 1;
    uint256 internal constant POOL_STETH = 2;
    uint256 internal constant POOL_WSTETH = 3;

    uint16 internal constant LTV_BPS = 9500;
    uint16 internal constant MIN_PAYMENT_BPS = 30;
    uint256 internal constant INDEX_UNITS = 100 ether;

    function setUp() public {
        setUpDiamond();

        pm = IPositionManagement(address(diamond));
        lending = ILending(address(diamond));
        indexAdmin = IEqualIndexAdmin(address(diamond));
        indexPosition = IEqualIndexPosition(address(diamond));
        indexActions = IEqualIndexActions(address(diamond));
        admin = IAdminGovernance(address(diamond));
        poolMap = IPoolMap(address(diamond));

        finalizePositionNFT();

        admin.setDefaultPoolConfig(_basePoolConfig());
        _deployAssets();
        _initPools();
        _fundUser();
        _approveUserAssets();
        _createPosition();
        _createIndexes();
        _seedIndexPools();
    }

    function test_leverageLoopThroughIndexes() public {
        admin.setRollingMinPaymentBps(MIN_PAYMENT_BPS);

        vm.startPrank(user);
        uint256 minted = indexPosition.mintFromPosition(positionId, indexIds[0], INDEX_UNITS);
        assertEq(minted, INDEX_UNITS, "position mint amount");

        uint256 firstBorrow = _borrowAtMaxLtv(indexPoolIds[0]);
        _payMonthly(indexPoolIds[0], firstBorrow);
        _repayRemaining(indexPoolIds[0]);

        indexPosition.burnFromPosition(positionId, indexIds[0], INDEX_UNITS);
        assertEq(views.getUserPrincipal(indexPoolIds[0], positionKey), 0, "burn clears principal");

        for (uint256 i = 1; i < indexIds.length; i++) {
            uint256 externalMint = indexActions.mint(indexIds[i], INDEX_UNITS, user);
            assertEq(externalMint, INDEX_UNITS, "external mint amount");

            pm.depositToPosition(positionId, indexPoolIds[i], externalMint);

            uint256 borrowAmount = _borrowAtMaxLtv(indexPoolIds[i]);
            _payMonthly(indexPoolIds[i], borrowAmount);
        }
        vm.stopPrank();
    }

    function _borrowAtMaxLtv(uint256 pid) internal returns (uint256 borrowAmount) {
        uint256 principal = views.getUserPrincipal(pid, positionKey);
        borrowAmount = (principal * LTV_BPS) / 10_000;
        lending.openRollingFromPosition(positionId, pid, borrowAmount);
        assertEq(views.getTotalDebt(pid, positionKey), borrowAmount, "max ltv debt");
    }

    function _payMonthly(uint256 pid, uint256 principal) internal {
        uint256 payment = _minPayment(principal);
        lending.makePaymentFromPosition(positionId, pid, payment);
        assertEq(views.getTotalDebt(pid, positionKey), principal - payment, "payment reduces debt");
    }

    function _repayRemaining(uint256 pid) internal {
        uint256 remaining = views.getTotalDebt(pid, positionKey);
        if (remaining > 0) {
            lending.makePaymentFromPosition(positionId, pid, remaining);
            assertEq(views.getTotalDebt(pid, positionKey), 0, "rolling loan closed");
        }
    }

    function _minPayment(uint256 principal) internal pure returns (uint256) {
        uint256 numerator = principal * MIN_PAYMENT_BPS;
        uint256 payment = numerator / 10_000;
        if (numerator % 10_000 != 0) {
            payment += 1;
        }
        return payment;
    }

    function _createIndexes() internal {
        _createIndex("Index-0", "IDX0", _assets3(), _bundle(0.5 ether, 0.3 ether, 0.2 ether));
        _createIndex("Index-1", "IDX1", _assets2(address(rETH), address(stETH)), _bundle(0.7 ether, 0.3 ether));
        _createIndex("Index-2", "IDX2", _assets2(address(stETH), address(wstETH)), _bundle(0.6 ether, 0.4 ether));
        _createIndex("Index-3", "IDX3", _assets2(address(rETH), address(wstETH)), _bundle(0.4 ether, 0.6 ether));
        _createIndex("Index-4", "IDX4", _assets3(), _bundle(0.34 ether, 0.33 ether, 0.33 ether));
    }

    function _deployAssets() internal {
        rETH = new MockERC20("rETH", "rETH", 18, 0);
        stETH = new MockERC20("stETH", "stETH", 18, 0);
        wstETH = new MockERC20("wstETH", "wstETH", 18, 0);
    }

    function _initPools() internal {
        harness.initPool(POOL_RETH, address(rETH), 1, 1, LTV_BPS);
        harness.initPool(POOL_STETH, address(stETH), 1, 1, LTV_BPS);
        harness.initPool(POOL_WSTETH, address(wstETH), 1, 1, LTV_BPS);
        poolMap.setAssetToPoolId(address(rETH), POOL_RETH);
        poolMap.setAssetToPoolId(address(stETH), POOL_STETH);
        poolMap.setAssetToPoolId(address(wstETH), POOL_WSTETH);
    }

    function _fundUser() internal {
        rETH.mint(user, 1_000_000 ether);
        stETH.mint(user, 1_000_000 ether);
        wstETH.mint(user, 1_000_000 ether);
    }

    function _approveUserAssets() internal {
        vm.startPrank(user);
        rETH.approve(address(diamond), type(uint256).max);
        stETH.approve(address(diamond), type(uint256).max);
        wstETH.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _createPosition() internal {
        vm.startPrank(user);
        positionId = pm.mintPositionWithDeposit(POOL_RETH, 500 ether);
        pm.depositToPosition(positionId, POOL_STETH, 500 ether);
        pm.depositToPosition(positionId, POOL_WSTETH, 500 ether);
        vm.stopPrank();
        positionKey = nft.getPositionKey(positionId);
    }

    function _seedIndexPools() internal {
        for (uint256 i = 0; i < indexTokens.length; i++) {
            vm.prank(user);
            MockERC20(indexTokens[i]).approve(address(diamond), type(uint256).max);
            harness.setPoolTotals(indexPoolIds[i], 0, 0);
        }
    }

    function _createIndex(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory bundleAmounts
    ) internal {
        _createIndexWithParams(_buildIndexParams(name, symbol, assets, bundleAmounts));
    }

    function _createIndexWithParams(EqualIndexBaseV3.CreateIndexParams memory params) internal {
        (uint256 indexId, address token) = indexAdmin.createIndex(params);
        indexIds.push(indexId);
        indexTokens.push(token);
        indexPoolIds.push(POOL_WSTETH + indexIds.length);
    }

    function _buildIndexParams(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory bundleAmounts
    ) internal pure returns (EqualIndexBaseV3.CreateIndexParams memory params) {
        params.name = name;
        params.symbol = symbol;
        params.assets = assets;
        params.bundleAmounts = bundleAmounts;
        params.mintFeeBps = _zeroFees(assets.length);
        params.burnFeeBps = _zeroFees(assets.length);
        params.flashFeeBps = 0;
    }

    function _assets3() internal view returns (address[] memory assets) {
        assets = new address[](3);
        assets[0] = address(rETH);
        assets[1] = address(stETH);
        assets[2] = address(wstETH);
    }

    function _assets2(address assetA, address assetB) internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
    }

    function _bundle(uint256 a, uint256 b) internal pure returns (uint256[] memory bundle) {
        bundle = new uint256[](2);
        bundle[0] = a;
        bundle[1] = b;
    }

    function _bundle(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory bundle) {
        bundle = new uint256[](3);
        bundle[0] = a;
        bundle[1] = b;
        bundle[2] = c;
    }

    function _zeroFees(uint256 length) internal pure returns (uint16[] memory fees) {
        fees = new uint16[](length);
        for (uint256 i = 0; i < length; i++) {
            fees[i] = 0;
        }
    }

    function _basePoolConfig() internal pure returns (Types.PoolConfig memory config) {
        config.rollingApyBps = 0;
        config.depositorLTVBps = LTV_BPS;
        config.maintenanceRateBps = 100;
        config.flashLoanFeeBps = 0;
        config.flashLoanAntiSplit = false;
        config.minDepositAmount = 1;
        config.minLoanAmount = 1;
        config.minTopupAmount = 1;
        config.isCapped = false;
        config.depositCap = 0;
        config.maxUserCount = 0;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 0;
        config.fixedTermConfigs = new Types.FixedTermConfig[](0);
        config.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        config.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

}

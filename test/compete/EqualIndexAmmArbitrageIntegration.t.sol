// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {Types} from "../../src/libraries/Types.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "./EqualIndexLeverageLoopIntegration.t.sol";

contract EqualIndexAmmArbitrageIntegrationTest is EqualIndexDiamondBase {
    IPositionManagement internal pm;
    IEqualIndexAdmin internal indexAdmin;
    IEqualIndexActions internal indexActions;
    IAdminGovernance internal admin;
    IPoolMap internal poolMap;
    AmmAuctionFacet internal amm;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xBEEF);
    address internal arbitrageur = address(0xA11CE);

    uint256 internal makerPositionId;
    uint256 internal indexId;
    address internal indexToken;

    uint256 internal constant POOL_TOKEN_A = 1;
    uint256 internal constant POOL_TOKEN_B = 2;
    uint16 internal constant LTV_BPS = 8000;
    uint256 internal constant INDEX_UNITS = 1 ether;
    uint256 internal constant AMM_AMOUNT_IN = 0.8 ether;
    uint256 internal constant RESERVE_A = 10 ether;
    uint256 internal constant RESERVE_B = 6 ether;

    function setUp() public {
        setUpDiamond();
        _addAmmFacet();
        _addIndexViewFacet();

        pm = IPositionManagement(address(diamond));
        indexAdmin = IEqualIndexAdmin(address(diamond));
        indexActions = IEqualIndexActions(address(diamond));
        admin = IAdminGovernance(address(diamond));
        poolMap = IPoolMap(address(diamond));
        amm = AmmAuctionFacet(address(diamond));

        finalizePositionNFT();

        admin.setDefaultPoolConfig(_basePoolConfig());
        _deployAssets();
        _initPools();
        _fundUsers();
        _approveUsers();
        _createMakerPosition();
        _createIndex();
    }

    function test_IndexNavArbitrageAgainstAmmAuction() public {
        uint256 auctionId = _createAmmAuction();

        (uint256 navInB, uint256 requiredA, uint256 requiredB) = _navInTokenB();
        (uint256 previewOut,) = amm.previewSwap(auctionId, address(tokenB), AMM_AMOUNT_IN);
        assertGe(previewOut, requiredA, "amm discount on tokenA");

        uint256 totalCostInB = AMM_AMOUNT_IN + requiredB;
        assertLt(totalCostInB, navInB, "amm discount below nav");

        vm.startPrank(arbitrageur);
        uint256 swappedOut = amm.swapExactIn(auctionId, address(tokenB), AMM_AMOUNT_IN, requiredA, arbitrageur);
        assertGe(swappedOut, requiredA, "swap output");

        uint256 minted = indexActions.mint(indexId, INDEX_UNITS, arbitrageur);
        vm.stopPrank();

        assertEq(minted, INDEX_UNITS, "minted index");
        assertEq(IndexToken(indexToken).balanceOf(arbitrageur), INDEX_UNITS, "index balance");
    }

    function _navInTokenB()
        internal
        view
        returns (uint256 navInB, uint256 requiredA, uint256 requiredB)
    {
        (, uint256[] memory navAmounts,) = IndexToken(indexToken).previewRedeem(INDEX_UNITS);
        // Assume tokenA and tokenB trade 1:1 for the NAV comparison baseline.
        navInB = navAmounts[0] + navAmounts[1];
        requiredA = navAmounts[0];
        requiredB = navAmounts[1];
    }

    function _deployAssets() internal {
        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);
    }

    function _initPools() internal {
        harness.initPool(POOL_TOKEN_A, address(tokenA), 1, 1, LTV_BPS);
        harness.initPool(POOL_TOKEN_B, address(tokenB), 1, 1, LTV_BPS);
        poolMap.setAssetToPoolId(address(tokenA), POOL_TOKEN_A);
        poolMap.setAssetToPoolId(address(tokenB), POOL_TOKEN_B);
    }

    function _fundUsers() internal {
        tokenA.mint(maker, 100 ether);
        tokenB.mint(maker, 100 ether);
        tokenA.mint(arbitrageur, 10 ether);
        tokenB.mint(arbitrageur, 10 ether);
    }

    function _approveUsers() internal {
        vm.startPrank(maker);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(arbitrageur);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _createMakerPosition() internal {
        vm.startPrank(maker);
        makerPositionId = pm.mintPositionWithDeposit(POOL_TOKEN_A, 50 ether);
        pm.depositToPosition(makerPositionId, POOL_TOKEN_B, 50 ether);
        vm.stopPrank();
    }

    function _createIndex() internal {
        EqualIndexBaseV3.CreateIndexParams memory params;
        params.name = "Index-AB";
        params.symbol = "IAB";
        params.assets = _assets2(address(tokenA), address(tokenB));
        params.bundleAmounts = _bundle2(1 ether, 1 ether);
        params.mintFeeBps = _zeroFees(2);
        params.burnFeeBps = _zeroFees(2);
        params.flashFeeBps = 0;

        (indexId, indexToken) = indexAdmin.createIndex(params);
    }

    function _createAmmAuction() internal returns (uint256 auctionId) {
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: makerPositionId,
            poolIdA: POOL_TOKEN_A,
            poolIdB: POOL_TOKEN_B,
            reserveA: RESERVE_A,
            reserveB: RESERVE_B,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 7 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(maker);
        auctionId = amm.createAuction(params);
    }

    function _addAmmFacet() internal {
        _diamondCutSingle(address(new AmmAuctionFacet()), _selectorsAmm());
    }

    function _addIndexViewFacet() internal {
        _diamondCutSingle(address(new EqualIndexViewFacetV3()), _selectorsIndexView());
    }

    function _selectorsAmm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactIn.selector;
        s[3] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[4] = AmmAuctionFacet.finalizeAuction.selector;
        s[5] = AmmAuctionFacet.cancelAuction.selector;
        s[6] = AmmAuctionFacet.getAuction.selector;
        s[7] = AmmAuctionFacet.previewSwap.selector;
    }

    function _selectorsIndexView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualIndexViewFacetV3.getIndex.selector;
        s[1] = EqualIndexViewFacetV3.getVaultBalance.selector;
        s[2] = EqualIndexViewFacetV3.getFeePot.selector;
    }

    function _assets2(address assetA, address assetB) internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
    }

    function _bundle2(uint256 a, uint256 b) internal pure returns (uint256[] memory bundle) {
        bundle = new uint256[](2);
        bundle[0] = a;
        bundle[1] = b;
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

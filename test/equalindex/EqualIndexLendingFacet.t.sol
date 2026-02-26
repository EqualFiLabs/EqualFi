// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexLendingFacet} from "../../src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibEqualIndexLending} from "../../src/libraries/LibEqualIndexLending.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Unauthorized} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexLendingHarness is EqualIndexAdminFacetV3, EqualIndexPositionFacet, EqualIndexLendingFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setDefaultPoolConfig() external {
        Types.PoolConfig storage cfg = LibAppStorage.s().defaultPoolConfig;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        MockERC20(underlying).mint(address(this), totalDeposits);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function mintPosition(address owner, uint256 poolId) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(owner, poolId);
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
    }

    function getPoolPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getPoolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getVaultBalanceRaw(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getIndexTotalUnits(uint256 indexId) external view returns (uint256) {
        return s().indexes[indexId].totalUnits;
    }

    function lendingEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, this.lendingModuleId());
    }
}

contract EqualIndexLendingFacetTest is Test {
    EqualIndexLendingHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal asset;

    address internal constant USER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    uint256 internal constant ASSET_POOL_ID = 1;
    uint256 internal constant POSITION_PRINCIPAL = 10 ether;
    uint256 internal constant MINT_UNITS = 2 ether;
    uint256 internal constant COLLATERAL_UNITS = 1 ether;
    uint256 internal constant BORROW_AMOUNT = 0.5 ether;

    struct Ctx {
        uint256 indexId;
        uint256 positionId;
        bytes32 positionKey;
        uint256 indexPoolId;
    }

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18, 0);
        nft = new PositionNFT();
        facet = new EqualIndexLendingHarness();

        facet.setOwner(address(this));
        facet.setTimelock(TIMELOCK);
        facet.setPositionNFT(address(nft));
        facet.setDefaultPoolConfig();

        nft.setMinter(address(facet));

        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);

        asset.mint(USER, 10 ether);
        vm.prank(USER);
        asset.approve(address(facet), type(uint256).max);
    }

    function test_configureLending_onlyTimelockAndWritesConfig() public {
        Ctx memory ctx = _createIndexAndPosition();

        vm.expectRevert(Unauthorized.selector);
        facet.configureLending(ctx.indexId, 8000, 100, 1 days, 30 days);

        vm.prank(TIMELOCK);
        facet.configureLending(ctx.indexId, 8000, 100, 1 days, 30 days);

        LibEqualIndexLending.LendingConfig memory cfg = facet.getLendingConfig(ctx.indexId);
        assertEq(cfg.ltvBps, 8000);
        assertEq(cfg.originationFeeBps, 100);
        assertEq(cfg.minDuration, 1 days);
        assertEq(cfg.maxDuration, 30 days);
    }

    function test_borrowRepay_updatesAccountingAndViews() public {
        Ctx memory ctx = _readyBorrowContext();

        vm.prank(USER);
        uint256 loanId = facet.borrowFromPosition(
            ctx.positionId, ctx.indexId, address(asset), COLLATERAL_UNITS, BORROW_AMOUNT, 7 days
        );

        LibEqualIndexLending.IndexLoan memory loan = facet.getLoan(loanId);
        assertEq(loan.positionKey, ctx.positionKey);
        assertEq(loan.indexId, ctx.indexId);
        assertEq(loan.borrowAsset, address(asset));
        assertEq(loan.collateralUnits, COLLATERAL_UNITS);
        assertEq(loan.principal, BORROW_AMOUNT);
        assertEq(loan.maturity, uint40(block.timestamp + 7 days));

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(asset)), BORROW_AMOUNT);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), COLLATERAL_UNITS);
        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(asset)), 1.5 ether);
        assertEq(facet.economicBalance(ctx.indexId, address(asset)), 2 ether);
        assertEq(facet.maxBorrowable(ctx.indexId, address(asset), COLLATERAL_UNITS), 0.8 ether);
        assertEq(facet.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), COLLATERAL_UNITS);

        vm.prank(USER);
        facet.repayFromPosition(ctx.positionId, loanId);

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(asset)), 0);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(asset)), 2 ether);
        assertEq(facet.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), 0);
        assertEq(facet.getLoan(loanId).principal, 0);
    }

    function test_extendFromPosition_updatesMaturity() public {
        Ctx memory ctx = _readyBorrowContext();

        vm.prank(USER);
        uint256 loanId = facet.borrowFromPosition(
            ctx.positionId, ctx.indexId, address(asset), COLLATERAL_UNITS, BORROW_AMOUNT, 7 days
        );
        uint40 maturityBefore = facet.getLoan(loanId).maturity;

        vm.prank(USER);
        facet.extendFromPosition(ctx.positionId, loanId, 2 days);

        uint40 maturityAfter = facet.getLoan(loanId).maturity;
        assertEq(uint256(maturityAfter), uint256(maturityBefore) + 2 days);
    }

    function test_recoverExpired_burnsAndClearsLoan() public {
        Ctx memory ctx = _readyBorrowContext();

        vm.prank(USER);
        uint256 loanId = facet.borrowFromPosition(
            ctx.positionId, ctx.indexId, address(asset), COLLATERAL_UNITS, BORROW_AMOUNT, 3 days
        );

        uint256 totalUnitsBefore = facet.getIndexTotalUnits(ctx.indexId);
        uint256 principalBefore = facet.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey);

        vm.warp(block.timestamp + 4 days);
        facet.recoverExpired(loanId);

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(asset)), 0);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(facet.getLoan(loanId).principal, 0);
        assertEq(facet.getIndexTotalUnits(ctx.indexId), totalUnitsBefore - COLLATERAL_UNITS);
        assertEq(facet.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey), principalBefore - COLLATERAL_UNITS);
        assertEq(facet.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), 0);
    }

    function _readyBorrowContext() internal returns (Ctx memory ctx) {
        ctx = _createIndexAndPosition();

        vm.prank(TIMELOCK);
        facet.configureLending(ctx.indexId, 8000, 100, 1 days, 30 days);

        vm.prank(USER);
        facet.mintFromPosition(ctx.positionId, ctx.indexId, MINT_UNITS);

        ctx.indexPoolId = facet.getIndexPoolId(ctx.indexId);
    }

    function _createIndexAndPosition() internal returns (Ctx memory ctx) {
        vm.prank(USER);
        ctx.positionId = facet.mintPosition(USER, ASSET_POOL_ID);
        ctx.positionKey = nft.getPositionKey(ctx.positionId);

        facet.setUserPrincipal(ASSET_POOL_ID, ctx.positionKey, POSITION_PRINCIPAL);
        facet.joinPool(ctx.positionKey, ASSET_POOL_ID);

        EqualIndexBaseV3.CreateIndexParams memory p = _singleAssetParams();
        (ctx.indexId,) = facet.createIndex(p);
    }

    function _singleAssetParams() internal view returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        address[] memory assets = new address[](1);
        uint256[] memory bundle = new uint256[](1);
        uint16[] memory mintFee = new uint16[](1);
        uint16[] memory burnFee = new uint16[](1);

        assets[0] = address(asset);
        bundle[0] = 1 ether;
        mintFee[0] = 0;
        burnFee[0] = 0;

        p = EqualIndexBaseV3.CreateIndexParams({
            name: "EQL",
            symbol: "EQL",
            assets: assets,
            bundleAmounts: bundle,
            mintFeeBps: mintFee,
            burnFeeBps: burnFee,
            flashFeeBps: 0
        });
    }
}

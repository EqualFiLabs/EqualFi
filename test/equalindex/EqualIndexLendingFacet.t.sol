// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
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
import {Unauthorized, InvalidParameterRange, NotNFTOwner} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexLendingHarness is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3, EqualIndexLendingFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
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

    function setPoolPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 prev = p.userPrincipal[positionKey];
        if (principal > prev) {
            uint256 add = principal - prev;
            p.totalDeposits += add;
            p.trackedBalance += add;
            if (prev == 0) p.userCount += 1;
        } else if (principal < prev) {
            uint256 sub = prev - principal;
            p.totalDeposits -= sub;
            p.trackedBalance -= sub;
            if (principal == 0 && p.userCount > 0) p.userCount -= 1;
        }
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

    function getPoolTotalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
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
    MockERC20 internal assetA;
    MockERC20 internal assetB;

    address internal constant BORROWER = address(0xB22);
    address internal constant LP = address(0xA11);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant TREASURY = address(0xFEE);
    uint256 internal constant ASSET_A_POOL_ID = 1;
    uint256 internal constant ASSET_B_POOL_ID = 2;
    uint256 internal constant COLLATERAL_UNITS = 1 ether;

    struct Ctx {
        uint256 indexId;
        uint256 positionId;
        bytes32 positionKey;
        uint256 indexPoolId;
    }

    function setUp() public {
        assetA = new MockERC20("AssetA", "ASTA", 18, 0);
        assetB = new MockERC20("AssetB", "ASTB", 18, 0);
        nft = new PositionNFT();
        facet = new EqualIndexLendingHarness();

        facet.setOwner(address(this));
        facet.setTimelock(TIMELOCK);
        facet.setTreasury(TREASURY);
        facet.setPositionNFT(address(nft));
        facet.setDefaultPoolConfig();
        nft.setMinter(address(facet));

        facet.seedPool(ASSET_A_POOL_ID, address(assetA), 1_000_000 ether);
        facet.seedPool(ASSET_B_POOL_ID, address(assetB), 1_000_000 ether);
        facet.setAssetToPoolId(address(assetA), ASSET_A_POOL_ID);
        facet.setAssetToPoolId(address(assetB), ASSET_B_POOL_ID);

        assetA.mint(LP, 1000 ether);
        assetB.mint(LP, 1000 ether);
        assetA.mint(BORROWER, 1000 ether);
        assetB.mint(BORROWER, 1000 ether);
        vm.deal(BORROWER, 10 ether);

        vm.startPrank(LP);
        assetA.approve(address(facet), type(uint256).max);
        assetB.approve(address(facet), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BORROWER);
        assetA.approve(address(facet), type(uint256).max);
        assetB.approve(address(facet), type(uint256).max);
        vm.stopPrank();
    }

    function test_configureLending_onlyTimelockAndWritesConfig() public {
        uint256 indexId = _createMultiAssetIndex();

        vm.expectRevert(Unauthorized.selector);
        facet.configureLending(indexId, 10_000, 100, 1 days, 30 days);

        vm.prank(TIMELOCK);
        facet.configureLending(indexId, 10_000, 100, 1 days, 30 days);

        LibEqualIndexLending.LendingConfig memory cfg = facet.getLendingConfig(indexId);
        assertEq(cfg.ltvBps, 10_000);
        assertEq(cfg.originationFeeBps, 100);
        assertEq(cfg.minDuration, 1 days);
        assertEq(cfg.maxDuration, 30 days);
    }

    function test_borrowBasket_borrowsAllUnderlyingAssets() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 100, COLLATERAL_UNITS);
        (address[] memory quoteAssets, uint256[] memory quotePrincipals) =
            facet.quoteBorrowBasket(ctx.indexId, COLLATERAL_UNITS);
        assertEq(quoteAssets.length, 2);
        assertEq(quotePrincipals[0], 1 ether);
        assertEq(quotePrincipals[1], 2 ether);

        uint256 balABefore = assetA.balanceOf(BORROWER);
        uint256 balBBefore = assetB.balanceOf(BORROWER);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);
        LibEqualIndexLending.IndexLoan memory loan = facet.getLoan(loanId);
        assertEq(loan.positionKey, ctx.positionKey);
        assertEq(loan.indexId, ctx.indexId);
        assertEq(loan.collateralUnits, COLLATERAL_UNITS);
        assertEq(loan.ltvBps, 10_000);
        assertEq(loan.maturity, uint40(block.timestamp + 7 days));

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetA)), 1 ether);
        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetB)), 2 ether);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), COLLATERAL_UNITS);
        assertEq(facet.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), COLLATERAL_UNITS);

        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(assetA)), 9 ether);
        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(assetB)), 18 ether);
        assertEq(assetA.balanceOf(BORROWER) - balABefore, 1 ether);
        assertEq(assetB.balanceOf(BORROWER) - balBBefore, 2 ether);
    }

    function test_borrow_revertsForNonWholeCollateralUnits() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, 2 ether);
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "collateralUnitsWhole"));
        facet.borrowFromPosition(ctx.positionId, ctx.indexId, 1.5 ether, 7 days);
    }

    function test_repay_basketClearsAllOutstandingPrincipals() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 100, COLLATERAL_UNITS);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);

        vm.prank(BORROWER);
        facet.repayFromPosition(ctx.positionId, loanId);

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetA)), 0);
        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetB)), 0);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(assetA)), 10 ether);
        assertEq(facet.getVaultBalanceRaw(ctx.indexId, address(assetB)), 20 ether);
        assertEq(facet.getLoan(loanId).collateralUnits, 0);
    }

    function test_borrowTierFee_requiresExactNativeFeeAndPaysTreasury() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, COLLATERAL_UNITS);
        uint256[] memory mins = new uint256[](2);
        uint256[] memory fees = new uint256[](2);
        mins[0] = 1 ether;
        mins[1] = 3 ether;
        fees[0] = 0.001 ether;
        fees[1] = 0.003 ether;

        vm.prank(TIMELOCK);
        facet.configureBorrowFeeTiers(ctx.indexId, mins, fees);

        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.001 ether, 0)
        );
        facet.borrowFromPosition(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(BORROWER);
        facet.borrowFromPosition{value: 0.001 ether}(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);
        assertEq(TREASURY.balance - treasuryBefore, 0.001 ether);
    }

    function test_borrowTierFee_usesMatchingTierForCollateralUnits() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, 5 ether);
        uint256[] memory mins = new uint256[](3);
        uint256[] memory fees = new uint256[](3);
        mins[0] = 1 ether;
        mins[1] = 3 ether;
        mins[2] = 5 ether;
        fees[0] = 0.001 ether;
        fees[1] = 0.003 ether;
        fees[2] = 0.005 ether;

        vm.prank(TIMELOCK);
        facet.configureBorrowFeeTiers(ctx.indexId, mins, fees);

        assertEq(facet.quoteBorrowFee(ctx.indexId, 1 ether), 0.001 ether);
        assertEq(facet.quoteBorrowFee(ctx.indexId, 3 ether), 0.003 ether);
        assertEq(facet.quoteBorrowFee(ctx.indexId, 5 ether), 0.005 ether);
    }

    function test_extend_usesFlatNativeTierFee() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, 2 ether);
        uint256[] memory mins = new uint256[](1);
        uint256[] memory fees = new uint256[](1);
        mins[0] = 1 ether;
        fees[0] = 0.002 ether;

        vm.prank(TIMELOCK);
        facet.configureBorrowFeeTiers(ctx.indexId, mins, fees);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition{value: 0.002 ether}(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);

        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.002 ether, 0)
        );
        facet.extendFromPosition(ctx.positionId, loanId, 3 days);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(BORROWER);
        facet.extendFromPosition{value: 0.002 ether}(ctx.positionId, loanId, 3 days);
        assertEq(TREASURY.balance - treasuryBefore, 0.002 ether);
    }

    function test_recoverExpired_multiAssetLoanWritesOffBasketDebt() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, COLLATERAL_UNITS);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 3 days);

        uint256 totalUnitsBefore = facet.getIndexTotalUnits(ctx.indexId);
        uint256 poolPrincipalBefore = facet.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey);
        uint256 poolTrackedBefore = facet.getPoolTrackedBalance(ctx.indexPoolId);
        uint256 poolDepositsBefore = facet.getPoolTotalDeposits(ctx.indexPoolId);

        vm.warp(block.timestamp + 4 days);
        facet.recoverExpired(loanId);

        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetA)), 0);
        assertEq(facet.getOutstandingPrincipal(ctx.indexId, address(assetB)), 0);
        assertEq(facet.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(facet.getLoan(loanId).collateralUnits, 0);
        assertEq(facet.getIndexTotalUnits(ctx.indexId), totalUnitsBefore - COLLATERAL_UNITS);
        assertEq(facet.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey), poolPrincipalBefore - COLLATERAL_UNITS);
        assertEq(facet.getPoolTrackedBalance(ctx.indexPoolId), poolTrackedBefore - COLLATERAL_UNITS);
        assertEq(facet.getPoolTotalDeposits(ctx.indexPoolId), poolDepositsBefore - COLLATERAL_UNITS);
    }

    function test_quoteBorrowBasket_returnsExactMintBasketForWholeUnitCollateral() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, 2 ether);
        (address[] memory assets, uint256[] memory principals) = facet.quoteBorrowBasket(ctx.indexId, 1 ether);
        assertEq(assets.length, 2);
        assertEq(principals[0], 1 ether);
        assertEq(principals[1], 2 ether);
    }

    function test_configureLending_revertsForNonExactBasketLtv() public {
        uint256 indexId = _createMultiAssetIndex();
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "ltvBps"));
        facet.configureLending(indexId, 9_000, 100, 1 days, 30 days);
    }

    function test_repay_revertsForNonOwner() public {
        Ctx memory ctx = _readyMultiAssetBorrowContext(10_000, 0, COLLATERAL_UNITS);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(ctx.positionId, ctx.indexId, COLLATERAL_UNITS, 7 days);

        address stranger = address(0xC33);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, ctx.positionId));
        facet.repayFromPosition(ctx.positionId, loanId);
    }

    function _readyMultiAssetBorrowContext(uint16 ltvBps, uint16 feeBps, uint256 seededPrincipal)
        internal
        returns (Ctx memory ctx)
    {
        ctx.indexId = _createMultiAssetIndex();
        _seedInitialMint(ctx.indexId, 10 ether);

        vm.prank(TIMELOCK);
        facet.configureLending(ctx.indexId, ltvBps, feeBps, 1 days, 30 days);

        vm.prank(BORROWER);
        ctx.positionId = facet.mintPosition(BORROWER, ASSET_A_POOL_ID);
        ctx.positionKey = nft.getPositionKey(ctx.positionId);
        ctx.indexPoolId = facet.getIndexPoolId(ctx.indexId);
        facet.setPoolPrincipal(ctx.indexPoolId, ctx.positionKey, seededPrincipal);
        facet.joinPool(ctx.positionKey, ctx.indexPoolId);
    }

    function _seedInitialMint(uint256 indexId, uint256 units) internal {
        uint256[] memory maxInput = new uint256[](2);
        maxInput[0] = units;
        maxInput[1] = units * 2;

        vm.prank(LP);
        facet.mint(indexId, units, address(facet), maxInput);
    }

    function _createMultiAssetIndex() internal returns (uint256 indexId) {
        address[] memory assets = new address[](2);
        uint256[] memory bundle = new uint256[](2);
        uint16[] memory mintFee = new uint16[](2);
        uint16[] memory burnFee = new uint16[](2);

        assets[0] = address(assetA);
        assets[1] = address(assetB);
        bundle[0] = 1 ether;
        bundle[1] = 2 ether;
        mintFee[0] = 0;
        mintFee[1] = 0;
        burnFee[0] = 0;
        burnFee[1] = 0;

        EqualIndexBaseV3.CreateIndexParams memory p = EqualIndexBaseV3.CreateIndexParams({
            name: "MIDX",
            symbol: "MIDX",
            assets: assets,
            bundleAmounts: bundle,
            mintFeeBps: mintFee,
            burnFeeBps: burnFee,
            flashFeeBps: 0
        });
        (indexId,) = facet.createIndex(p);
    }
}

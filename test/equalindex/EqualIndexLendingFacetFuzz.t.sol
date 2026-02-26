// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexLendingFuzzHarness is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3, EqualIndexLendingFacet {
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
        cfg.depositorLTVBps = 9000;
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
            if (prev == 0) {
                p.userCount += 1;
            }
        } else if (principal < prev) {
            uint256 sub = prev - principal;
            p.totalDeposits -= sub;
            p.trackedBalance -= sub;
            if (principal == 0 && p.userCount > 0) {
                p.userCount -= 1;
            }
        }
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
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

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
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

    function setOutstandingPrincipal(uint256 indexId, address asset, uint256 amount) external {
        LibEqualIndexLending.s().outstandingPrincipal[indexId][asset] = amount;
    }
}

contract EqualIndexLendingFacetFuzzTest is Test {
    struct Scenario {
        uint256 indexId;
        uint256 indexPoolId;
        uint256 positionId;
        bytes32 positionKey;
    }

    EqualIndexLendingFuzzHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal asset;

    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant LP = address(0xA11);
    address internal constant BORROWER = address(0xB22);
    address internal constant MINT_USER = address(0xC33);
    uint256 internal constant ASSET_POOL_ID = 1;
    uint256 internal constant INITIAL_INDEX_UNITS = 10 ether;
    uint256 internal constant INDEX_POOL_PRINCIPAL = 6 ether;

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18, 0);
        nft = new PositionNFT();
        facet = new EqualIndexLendingFuzzHarness();

        facet.setOwner(address(this));
        facet.setTimelock(TIMELOCK);
        facet.setPositionNFT(address(nft));
        facet.setDefaultPoolConfig();

        nft.setMinter(address(facet));

        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);

        asset.mint(LP, 100 ether);
        asset.mint(BORROWER, 100 ether);
        asset.mint(MINT_USER, 100 ether);

        vm.prank(LP);
        asset.approve(address(facet), type(uint256).max);
        vm.prank(BORROWER);
        asset.approve(address(facet), type(uint256).max);
        vm.prank(MINT_USER);
        asset.approve(address(facet), type(uint256).max);
    }

    function testFuzz_configurationRoundTrip(
        uint256 ltvBpsRaw,
        uint256 originationFeeBpsRaw,
        uint256 minDurationRaw,
        uint256 maxExtraRaw
    ) public {
        uint16 ltvBps = uint16(bound(ltvBpsRaw, 0, 10_000));
        uint16 originationFeeBps = uint16(bound(originationFeeBpsRaw, 0, 10_000));
        uint40 minDuration = uint40(bound(minDurationRaw, 0, 30 days));
        uint40 maxDuration = minDuration + uint40(bound(maxExtraRaw, 0, 365 days));

        uint256 indexId = _createIndex();
        vm.prank(TIMELOCK);
        facet.configureLending(indexId, ltvBps, originationFeeBps, minDuration, maxDuration);

        LibEqualIndexLending.LendingConfig memory cfg = facet.getLendingConfig(indexId);
        assertEq(cfg.ltvBps, ltvBps);
        assertEq(cfg.originationFeeBps, originationFeeBps);
        assertEq(cfg.minDuration, minDuration);
        assertEq(cfg.maxDuration, maxDuration);
    }

    function testFuzz_borrowAccountingConsistency(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 100, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        uint256 outstandingBefore = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        uint256 lockedBefore = facet.getLockedCollateralUnits(sc.indexId);
        uint256 vaultBefore = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 trackedBefore = facet.getPoolTrackedBalance(ASSET_POOL_ID);
        uint256 borrowerBalBefore = asset.balanceOf(BORROWER);

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 fee = (amount * 100) / 10_000;
        LibEqualIndexLending.IndexLoan memory loan = facet.getLoan(loanId);
        assertEq(loan.positionKey, sc.positionKey);
        assertEq(loan.indexId, sc.indexId);
        assertEq(loan.borrowAsset, address(asset));
        assertEq(loan.collateralUnits, collateralUnits);
        assertEq(loan.principal, amount);
        assertEq(loan.maturity, uint40(block.timestamp + duration));

        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore + amount);
        assertEq(facet.getLockedCollateralUnits(sc.indexId), lockedBefore + collateralUnits);
        assertEq(facet.getVaultBalanceRaw(sc.indexId, address(asset)), vaultBefore - amount);
        assertEq(facet.getPoolTrackedBalance(ASSET_POOL_ID), trackedBefore + fee);
        assertEq(asset.balanceOf(BORROWER) - borrowerBalBefore, amount - fee);
    }

    function testFuzz_ltvCapEnforcement(uint256 collateralRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 over = maxByLtv + 1;
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(LibEqualIndexLending.LtvExceeded.selector, over, maxByLtv));
        facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, over, duration);

        vm.prank(BORROWER);
        facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, maxByLtv, duration);
    }

    function testFuzz_redeemabilityInvariant(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9500, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9500) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 totalUnits = facet.getIndexTotalUnits(sc.indexId);
        uint256 locked = facet.getLockedCollateralUnits(sc.indexId);
        uint256 vault = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 required = Math.mulDiv(totalUnits - locked, 1 ether, LibEqualIndex.INDEX_SCALE);
        assertGe(vault, required);
    }

    function testFuzz_repayAccountingConsistency(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 100, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 vaultBeforeRepay = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 outstandingBeforeRepay = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        uint256 lockedBeforeRepay = facet.getLockedCollateralUnits(sc.indexId);
        uint256 encumberedBeforeRepay = facet.lendingEncumbered(sc.positionKey, sc.indexPoolId);

        vm.prank(BORROWER);
        facet.repayFromPosition(sc.positionId, loanId);

        assertEq(facet.getVaultBalanceRaw(sc.indexId, address(asset)), vaultBeforeRepay + amount);
        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBeforeRepay - amount);
        assertEq(facet.getLockedCollateralUnits(sc.indexId), lockedBeforeRepay - collateralUnits);
        assertEq(encumberedBeforeRepay, collateralUnits);
        assertEq(facet.lendingEncumbered(sc.positionKey, sc.indexPoolId), 0);
    }

    function testFuzz_borrowRepayRoundTrip(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 50, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        uint256 vaultBefore = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 outstandingBefore = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        uint256 lockedBefore = facet.getLockedCollateralUnits(sc.indexId);
        uint256 encBefore = facet.lendingEncumbered(sc.positionKey, sc.indexPoolId);

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);
        vm.prank(BORROWER);
        facet.repayFromPosition(sc.positionId, loanId);

        assertEq(facet.getVaultBalanceRaw(sc.indexId, address(asset)), vaultBefore);
        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore);
        assertEq(facet.getLockedCollateralUnits(sc.indexId), lockedBefore);
        assertEq(facet.lendingEncumbered(sc.positionKey, sc.indexPoolId), encBefore);
    }

    function testFuzz_extensionConsistency(
        uint256 collateralRaw,
        uint256 amountRaw,
        uint256 borrowDurationRaw,
        uint256 addedRaw
    ) public {
        Scenario memory sc = _prepareScenario(9000, 150, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(borrowDurationRaw, 1 days, 29 days));
        uint40 addedDuration = uint40(bound(addedRaw, 1, uint256(30 days - duration)));

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint40 maturityBefore = facet.getLoan(loanId).maturity;
        uint256 balanceBefore = asset.balanceOf(BORROWER);

        vm.prank(BORROWER);
        facet.extendFromPosition(sc.positionId, loanId, addedDuration);

        uint256 fee = (amount * 150) / 10_000;
        assertEq(balanceBefore - asset.balanceOf(BORROWER), fee);
        assertEq(facet.getLoan(loanId).maturity, maturityBefore + addedDuration);
    }

    function testFuzz_recoveryAccountingConsistency(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 outstandingBefore = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        uint256 lockedBefore = facet.getLockedCollateralUnits(sc.indexId);
        uint256 totalUnitsBefore = facet.getIndexTotalUnits(sc.indexId);
        uint256 poolPrincipalBefore = facet.getPoolPrincipal(sc.indexPoolId, sc.positionKey);
        uint256 poolTrackedBefore = facet.getPoolTrackedBalance(sc.indexPoolId);
        uint256 poolDepositsBefore = facet.getPoolTotalDeposits(sc.indexPoolId);

        vm.warp(block.timestamp + duration + 1);
        facet.recoverExpired(loanId);

        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore - amount);
        assertEq(facet.getLockedCollateralUnits(sc.indexId), lockedBefore - collateralUnits);
        assertEq(facet.getIndexTotalUnits(sc.indexId), totalUnitsBefore - collateralUnits);
        assertEq(facet.getPoolPrincipal(sc.indexPoolId, sc.positionKey), poolPrincipalBefore - collateralUnits);
        assertEq(facet.getPoolTrackedBalance(sc.indexPoolId), poolTrackedBefore - collateralUnits);
        assertEq(facet.getPoolTotalDeposits(sc.indexPoolId), poolDepositsBefore - collateralUnits);
        assertEq(facet.lendingEncumbered(sc.positionKey, sc.indexPoolId), 0);
    }

    function testFuzz_navAccretionOnRecovery(uint256 ltvRaw, uint256 collateralRaw, uint256 amountRaw) public {
        uint16 ltvBps = uint16(bound(ltvRaw, 100, 9900));
        Scenario memory sc = _prepareScenario(ltvBps, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * ltvBps) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv == 0 ? 1 : maxByLtv);

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, 3 days);

        uint256 econBefore = facet.economicBalance(sc.indexId, address(asset));
        uint256 unitsBefore = facet.getIndexTotalUnits(sc.indexId);

        vm.warp(block.timestamp + 4 days);
        facet.recoverExpired(loanId);

        uint256 econAfter = facet.economicBalance(sc.indexId, address(asset));
        uint256 unitsAfter = facet.getIndexTotalUnits(sc.indexId);
        assertGe(econAfter * unitsBefore, econBefore * unitsAfter);
    }

    function testFuzz_economicBalanceCorrectness(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        uint256 loanId =
            facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 vaultAfterBorrow = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 outstandingAfterBorrow = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        assertEq(facet.economicBalance(sc.indexId, address(asset)), vaultAfterBorrow + outstandingAfterBorrow);

        vm.prank(BORROWER);
        facet.repayFromPosition(sc.positionId, loanId);
        uint256 vaultAfterRepay = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), 0);
        assertEq(facet.economicBalance(sc.indexId, address(asset)), vaultAfterRepay);
    }

    function testFuzz_mintPricingUsesEconomicBalance(uint256 collateralRaw, uint256 amountRaw, uint256 durationRaw) public {
        Scenario memory sc = _prepareScenario(9000, 0, 1 days, 30 days);

        uint256 collateralUnits = bound(collateralRaw, 1 ether, 5 ether);
        uint256 maxByLtv = (collateralUnits * 9000) / 10_000;
        uint256 amount = bound(amountRaw, 1, maxByLtv);
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        vm.prank(BORROWER);
        facet.borrowFromPosition(sc.positionId, sc.indexId, address(asset), collateralUnits, amount, duration);

        uint256 unitsToMint = LibEqualIndex.INDEX_SCALE;
        uint256 totalSupplyBefore = facet.getIndexTotalUnits(sc.indexId);
        uint256 expectedNeed = Math.mulDiv(
            facet.economicBalance(sc.indexId, address(asset)), unitsToMint, totalSupplyBefore, Math.Rounding.Ceil
        );

        uint256[] memory maxInput = new uint256[](1);
        maxInput[0] = expectedNeed;

        uint256 minterBalBefore = asset.balanceOf(MINT_USER);
        vm.prank(MINT_USER);
        facet.mint(sc.indexId, unitsToMint, MINT_USER, maxInput);

        uint256 spent = minterBalBefore - asset.balanceOf(MINT_USER);
        assertEq(spent, expectedNeed);
    }

    function _prepareScenario(uint16 ltvBps, uint16 feeBps, uint40 minDuration, uint40 maxDuration)
        internal
        returns (Scenario memory sc)
    {
        sc.indexId = _createIndex();
        _seedInitialMint(sc.indexId, INITIAL_INDEX_UNITS);

        vm.prank(TIMELOCK);
        facet.configureLending(sc.indexId, ltvBps, feeBps, minDuration, maxDuration);

        sc.indexPoolId = facet.getIndexPoolId(sc.indexId);

        vm.prank(BORROWER);
        sc.positionId = facet.mintPosition(BORROWER, ASSET_POOL_ID);
        sc.positionKey = nft.getPositionKey(sc.positionId);

        facet.setPoolPrincipal(sc.indexPoolId, sc.positionKey, INDEX_POOL_PRINCIPAL);
        facet.joinPool(sc.positionKey, sc.indexPoolId);
    }

    function _seedInitialMint(uint256 indexId, uint256 units) internal {
        uint256[] memory maxInput = new uint256[](1);
        maxInput[0] = units;
        vm.prank(LP);
        facet.mint(indexId, units, address(facet), maxInput);
    }

    function _createIndex() internal returns (uint256 indexId) {
        (indexId,) = facet.createIndex(_singleAssetParams());
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
            name: "IDX",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundle,
            mintFeeBps: mintFee,
            burnFeeBps: burnFee,
            flashFeeBps: 0
        });
    }
}

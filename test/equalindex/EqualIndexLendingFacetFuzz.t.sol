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
import {InvalidParameterRange} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexLendingFuzzHarness is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3, EqualIndexLendingFacet {
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

    function getVaultBalanceRaw(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getIndexTotalUnits(uint256 indexId) external view returns (uint256) {
        return s().indexes[indexId].totalUnits;
    }

    function lendingEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, this.lendingModuleId());
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
    address internal constant TREASURY = address(0xFEE);
    address internal constant LP = address(0xA11);
    address internal constant BORROWER = address(0xB22);
    uint256 internal constant ASSET_POOL_ID = 1;
    uint256 internal constant INDEX_POOL_PRINCIPAL = 6 ether;

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18, 0);
        nft = new PositionNFT();
        facet = new EqualIndexLendingFuzzHarness();

        facet.setOwner(address(this));
        facet.setTimelock(TIMELOCK);
        facet.setTreasury(TREASURY);
        facet.setPositionNFT(address(nft));
        facet.setDefaultPoolConfig();
        nft.setMinter(address(facet));

        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);

        asset.mint(LP, 100 ether);
        asset.mint(BORROWER, 100 ether);
        vm.prank(LP);
        asset.approve(address(facet), type(uint256).max);
        vm.prank(BORROWER);
        asset.approve(address(facet), type(uint256).max);
    }

    function testFuzz_configurationRoundTrip(uint256 originationFeeBpsRaw, uint256 minDurationRaw, uint256 maxExtraRaw)
        public
    {
        uint16 originationFeeBps = uint16(bound(originationFeeBpsRaw, 0, 10_000));
        uint40 minDuration = uint40(bound(minDurationRaw, 0, 30 days));
        uint40 maxDuration = minDuration + uint40(bound(maxExtraRaw, 0, 365 days));

        uint256 indexId = _createIndex();
        vm.prank(TIMELOCK);
        facet.configureLending(indexId, 10_000, originationFeeBps, minDuration, maxDuration);

        LibEqualIndexLending.LendingConfig memory cfg = facet.getLendingConfig(indexId);
        assertEq(cfg.ltvBps, 10_000);
        assertEq(cfg.originationFeeBps, originationFeeBps);
        assertEq(cfg.minDuration, minDuration);
        assertEq(cfg.maxDuration, maxDuration);
    }

    function testFuzz_configurationRejectsNonExactLtv(uint256 ltvBpsRaw) public {
        uint16 ltvBps = uint16(bound(ltvBpsRaw, 0, 9999));
        uint256 indexId = _createIndex();
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "ltvBps"));
        facet.configureLending(indexId, ltvBps, 100, 1 days, 30 days);
    }

    function testFuzz_borrowRepay_roundTripAccounting(
        uint256 feeBpsRaw,
        uint256 collateralWholeRaw,
        uint256 durationRaw
    ) public {
        uint16 feeBps = uint16(bound(feeBpsRaw, 0, 1_000));
        uint256 collateralWhole = bound(collateralWholeRaw, 1, 5);
        uint256 collateralUnits = collateralWhole * LibEqualIndex.INDEX_SCALE;
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));

        Scenario memory sc = _prepareScenario(feeBps, 1 days, 30 days);

        uint256 principal = collateralUnits;
        uint256 vaultBefore = facet.getVaultBalanceRaw(sc.indexId, address(asset));
        uint256 outstandingBefore = facet.getOutstandingPrincipal(sc.indexId, address(asset));
        uint256 trackedBefore = facet.getPoolTrackedBalance(ASSET_POOL_ID);
        uint256 balBefore = asset.balanceOf(BORROWER);

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(sc.positionId, sc.indexId, collateralUnits, duration);
        LibEqualIndexLending.IndexLoan memory loan = facet.getLoan(loanId);
        assertEq(loan.collateralUnits, collateralUnits);
        assertEq(loan.ltvBps, 10_000);
        assertEq(loan.maturity, uint40(block.timestamp + duration));
        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore + principal);
        assertEq(facet.getVaultBalanceRaw(sc.indexId, address(asset)), vaultBefore - principal);
        assertEq(facet.getPoolTrackedBalance(ASSET_POOL_ID), trackedBefore);
        assertEq(asset.balanceOf(BORROWER) - balBefore, principal);

        vm.prank(BORROWER);
        facet.repayFromPosition(sc.positionId, loanId);
        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore);
        assertEq(facet.getVaultBalanceRaw(sc.indexId, address(asset)), vaultBefore);
    }

    function testFuzz_recoverExpired_adjustsIndexesAndPoolAccounting(
        uint256 collateralWholeRaw,
        uint256 durationRaw
    ) public {
        uint256 collateralWhole = bound(collateralWholeRaw, 1, 5);
        uint256 collateralUnits = collateralWhole * LibEqualIndex.INDEX_SCALE;
        uint40 duration = uint40(bound(durationRaw, 1 days, 30 days));
        Scenario memory sc = _prepareScenario(0, 1 days, 30 days);

        uint256 principal = collateralUnits;

        vm.prank(BORROWER);
        uint256 loanId = facet.borrowFromPosition(sc.positionId, sc.indexId, collateralUnits, duration);

        uint256 totalUnitsBefore = facet.getIndexTotalUnits(sc.indexId);
        uint256 poolPrincipalBefore = facet.getPoolPrincipal(sc.indexPoolId, sc.positionKey);
        uint256 trackedBefore = facet.getPoolTrackedBalance(sc.indexPoolId);
        uint256 depositsBefore = facet.getPoolTotalDeposits(sc.indexPoolId);
        uint256 outstandingBefore = facet.getOutstandingPrincipal(sc.indexId, address(asset));

        vm.warp(block.timestamp + duration + 1);
        facet.recoverExpired(loanId);

        assertEq(facet.getOutstandingPrincipal(sc.indexId, address(asset)), outstandingBefore - principal);
        assertEq(facet.getIndexTotalUnits(sc.indexId), totalUnitsBefore - collateralUnits);
        assertEq(facet.getPoolPrincipal(sc.indexPoolId, sc.positionKey), poolPrincipalBefore - collateralUnits);
        assertEq(facet.getPoolTrackedBalance(sc.indexPoolId), trackedBefore - collateralUnits);
        assertEq(facet.getPoolTotalDeposits(sc.indexPoolId), depositsBefore - collateralUnits);
        assertEq(facet.getLoan(loanId).collateralUnits, 0);
    }

    function _prepareScenario(uint16 feeBps, uint40 minDuration, uint40 maxDuration)
        internal
        returns (Scenario memory sc)
    {
        sc.indexId = _createIndex();
        _seedInitialMint(sc.indexId, 10 ether);

        vm.prank(TIMELOCK);
        facet.configureLending(sc.indexId, 10_000, feeBps, minDuration, maxDuration);

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
        address[] memory assets = new address[](1);
        uint256[] memory bundle = new uint256[](1);
        uint16[] memory mintFee = new uint16[](1);
        uint16[] memory burnFee = new uint16[](1);

        assets[0] = address(asset);
        bundle[0] = 1 ether;
        mintFee[0] = 0;
        burnFee[0] = 0;
        (indexId,) = facet.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFee,
                burnFeeBps: burnFee,
                flashFeeBps: 0
            })
        );
    }
}

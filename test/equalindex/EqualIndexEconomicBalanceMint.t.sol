// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibEqualIndexLending} from "../../src/libraries/LibEqualIndexLending.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexEconomicActionsHarness is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3 {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
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

    function setOutstandingPrincipal(uint256 indexId, address asset, uint256 amount) external {
        LibEqualIndexLending.s().outstandingPrincipal[indexId][asset] = amount;
    }

    function getVaultBalanceRaw(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }
}

contract EqualIndexEconomicPositionHarness is EqualIndexAdminFacetV3, EqualIndexPositionFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
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

    function setOutstandingPrincipal(uint256 indexId, address asset, uint256 amount) external {
        LibEqualIndexLending.s().outstandingPrincipal[indexId][asset] = amount;
    }

    function getVaultBalanceRaw(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
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

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }
}

contract EqualIndexEconomicBalanceActionsMintTest is Test {
    uint256 internal constant ASSET_POOL_ID = 1;

    EqualIndexEconomicActionsHarness internal facet;
    MockERC20 internal asset;

    address internal constant USER_A = address(0xA11);
    address internal constant USER_B = address(0xB22);
    address internal constant USER_C = address(0xC33);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18, 0);
        facet = new EqualIndexEconomicActionsHarness();
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig();
        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);

        asset.mint(USER_A, 10 ether);
        asset.mint(USER_B, 10 ether);
        asset.mint(USER_C, 10 ether);
        vm.prank(USER_A);
        asset.approve(address(facet), type(uint256).max);
        vm.prank(USER_B);
        asset.approve(address(facet), type(uint256).max);
        vm.prank(USER_C);
        asset.approve(address(facet), type(uint256).max);
    }

    function test_mint_usesEconomicBalanceWhenOutstandingPrincipalExists() public {
        (uint256 indexId,) = facet.createIndex(_singleAssetParams());

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 1 ether;
        vm.prank(USER_A);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, USER_A, maxInputs);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 1 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 1 ether);

        uint256 balanceBefore = asset.balanceOf(USER_B);
        maxInputs[0] = 2 ether;
        vm.prank(USER_B);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, USER_B, maxInputs);
        uint256 spent = balanceBefore - asset.balanceOf(USER_B);

        assertEq(spent, 2 ether);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 3 ether);
    }

    function test_mint_costNormalizesAfterOutstandingPrincipalReturnsToZero() public {
        (uint256 indexId,) = facet.createIndex(_singleAssetParams());

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 1 ether;
        vm.prank(USER_A);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, USER_A, maxInputs);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 1 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 1 ether);

        maxInputs[0] = 2 ether;
        vm.prank(USER_B);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, USER_B, maxInputs);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 3 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 0);

        uint256 balanceBefore = asset.balanceOf(USER_C);
        maxInputs[0] = 1.5 ether;
        vm.prank(USER_C);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, USER_C, maxInputs);
        uint256 spent = balanceBefore - asset.balanceOf(USER_C);

        assertEq(spent, 1.5 ether);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 4.5 ether);
    }

    function _singleAssetParams() internal view returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        address[] memory assets = new address[](1);
        uint256[] memory bundleAmounts = new uint256[](1);
        uint16[] memory mintFeeBps = new uint16[](1);
        uint16[] memory burnFeeBps = new uint16[](1);
        assets[0] = address(asset);
        bundleAmounts[0] = 1 ether;
        p = EqualIndexBaseV3.CreateIndexParams({
            name: "IDX",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFeeBps,
            burnFeeBps: burnFeeBps,
            flashFeeBps: 0
        });
    }
}

contract EqualIndexEconomicBalancePositionMintTest is Test {
    uint256 internal constant ASSET_POOL_ID = 1;

    EqualIndexEconomicPositionHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal asset;

    address internal constant USER_A = address(0xA11);
    address internal constant USER_B = address(0xB22);
    address internal constant USER_C = address(0xC33);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18, 0);
        facet = new EqualIndexEconomicPositionHarness();
        nft = new PositionNFT();

        facet.setOwner(address(this));
        facet.setDefaultPoolConfig();
        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);
        facet.setPositionNFT(address(nft));
        nft.setMinter(address(facet));
    }

    function test_mintFromPosition_usesEconomicBalanceWhenOutstandingPrincipalExists() public {
        (uint256 indexId,) = facet.createIndex(_singleAssetParams());

        vm.prank(USER_A);
        uint256 positionA = facet.mintPosition(USER_A, ASSET_POOL_ID);
        vm.prank(USER_B);
        uint256 positionB = facet.mintPosition(USER_B, ASSET_POOL_ID);

        bytes32 keyA = nft.getPositionKey(positionA);
        bytes32 keyB = nft.getPositionKey(positionB);
        facet.setUserPrincipal(ASSET_POOL_ID, keyA, 10 ether);
        facet.setUserPrincipal(ASSET_POOL_ID, keyB, 10 ether);
        facet.joinPool(keyA, ASSET_POOL_ID);
        facet.joinPool(keyB, ASSET_POOL_ID);

        vm.prank(USER_A);
        facet.mintFromPosition(positionA, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 1 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 1 ether);

        vm.prank(USER_B);
        facet.mintFromPosition(positionB, indexId, LibEqualIndex.INDEX_SCALE);

        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 3 ether);
    }

    function test_mintFromPosition_costNormalizesAfterOutstandingPrincipalReturnsToZero() public {
        (uint256 indexId,) = facet.createIndex(_singleAssetParams());

        vm.prank(USER_A);
        uint256 positionA = facet.mintPosition(USER_A, ASSET_POOL_ID);
        vm.prank(USER_B);
        uint256 positionB = facet.mintPosition(USER_B, ASSET_POOL_ID);
        vm.prank(USER_C);
        uint256 positionC = facet.mintPosition(USER_C, ASSET_POOL_ID);

        bytes32 keyA = nft.getPositionKey(positionA);
        bytes32 keyB = nft.getPositionKey(positionB);
        bytes32 keyC = nft.getPositionKey(positionC);
        facet.setUserPrincipal(ASSET_POOL_ID, keyA, 10 ether);
        facet.setUserPrincipal(ASSET_POOL_ID, keyB, 10 ether);
        facet.setUserPrincipal(ASSET_POOL_ID, keyC, 10 ether);
        facet.joinPool(keyA, ASSET_POOL_ID);
        facet.joinPool(keyB, ASSET_POOL_ID);
        facet.joinPool(keyC, ASSET_POOL_ID);

        vm.prank(USER_A);
        facet.mintFromPosition(positionA, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 1 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 1 ether);
        vm.prank(USER_B);
        facet.mintFromPosition(positionB, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 3 ether);

        facet.setOutstandingPrincipal(indexId, address(asset), 0);
        vm.prank(USER_C);
        facet.mintFromPosition(positionC, indexId, LibEqualIndex.INDEX_SCALE);

        assertEq(facet.getVaultBalanceRaw(indexId, address(asset)), 4.5 ether);
    }

    function _singleAssetParams() internal view returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        address[] memory assets = new address[](1);
        uint256[] memory bundleAmounts = new uint256[](1);
        uint16[] memory mintFeeBps = new uint16[](1);
        uint16[] memory burnFeeBps = new uint16[](1);
        assets[0] = address(asset);
        bundleAmounts[0] = 1 ether;
        p = EqualIndexBaseV3.CreateIndexParams({
            name: "IDX",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFeeBps,
            burnFeeBps: burnFeeBps,
            flashFeeBps: 0
        });
    }
}

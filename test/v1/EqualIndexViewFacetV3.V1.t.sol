// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {UnknownIndex} from "../../src/libraries/Errors.sol";

contract LocalViewMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualIndexViewV1Harness is EqualIndexAdminFacetV3, EqualIndexViewFacetV3 {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setDefaultPoolConfig() external {
        Types.PoolConfig storage cfg = LibAppStorage.s().defaultPoolConfig;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 10_000;
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
        LocalViewMockERC20V1(underlying).mint(address(this), totalDeposits);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setVaultBalance(uint256 indexId, address asset, uint256 amount) external {
        s().vaultBalances[indexId][asset] = amount;
    }

    function setFeePot(uint256 indexId, address asset, uint256 amount) external {
        s().feePots[indexId][asset] = amount;
    }
}

contract EqualIndexViewFacetV3V1Test is Test {
    EqualIndexViewV1Harness internal harness;
    LocalViewMockERC20V1 internal assetA;
    LocalViewMockERC20V1 internal assetB;
    LocalViewMockERC20V1 internal assetC;

    function setUp() public {
        harness = new EqualIndexViewV1Harness();
        harness.setOwner(address(this));
        harness.setDefaultPoolConfig();

        assetA = new LocalViewMockERC20V1("AssetA", "A", 18);
        assetB = new LocalViewMockERC20V1("AssetB", "B", 18);
        assetC = new LocalViewMockERC20V1("AssetC", "C", 6);

        harness.seedPool(1, address(assetA), 100_000 ether);
        harness.seedPool(2, address(assetB), 100_000 ether);
        harness.seedPool(3, address(assetC), 100_000_000e6);
        harness.setAssetToPoolId(address(assetA), 1);
        harness.setAssetToPoolId(address(assetB), 2);
        harness.setAssetToPoolId(address(assetC), 3);
    }

    function test_getIndexAssets_andIndexView() public {
        uint256 indexId = _createIndex();

        assertEq(harness.getIndexAssetCount(indexId), 3);

        (address[] memory assets, uint256[] memory bundles, uint16[] memory mintFees, uint16[] memory burnFees) =
            harness.getIndexAssets(indexId, 1, 1);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(assetB));
        assertEq(bundles[0], 2 ether);
        assertEq(mintFees[0], 25);
        assertEq(burnFees[0], 15);

        EqualIndexBaseV3.IndexView memory index_ = harness.getIndex(indexId);
        assertEq(index_.assets.length, 3);
        assertEq(index_.assets[0], address(assetA));
        assertEq(index_.assets[1], address(assetB));
        assertEq(index_.assets[2], address(assetC));
        assertEq(index_.bundleAmounts[0], 1 ether);
        assertEq(index_.bundleAmounts[1], 2 ether);
        assertEq(index_.bundleAmounts[2], 3e6);
        assertEq(index_.mintFeeBps[0], 10);
        assertEq(index_.mintFeeBps[1], 25);
        assertEq(index_.mintFeeBps[2], 40);
        assertEq(index_.burnFeeBps[0], 5);
        assertEq(index_.burnFeeBps[1], 15);
        assertEq(index_.burnFeeBps[2], 20);
        assertEq(index_.flashFeeBps, 35);
        assertFalse(index_.paused);
        assertEq(index_.totalUnits, 0);
        assertTrue(index_.token != address(0));
    }

    function test_vaultAndFeePotViews() public {
        uint256 indexId = _createIndex();
        harness.setVaultBalance(indexId, address(assetA), 123 ether);
        harness.setVaultBalance(indexId, address(assetC), 45e6);
        harness.setFeePot(indexId, address(assetA), 9 ether);
        harness.setFeePot(indexId, address(assetC), 2e6);

        assertEq(harness.getVaultBalance(indexId, address(assetA)), 123 ether);
        assertEq(harness.getVaultBalance(indexId, address(assetC)), 45e6);
        assertEq(harness.getFeePot(indexId, address(assetA)), 9 ether);
        assertEq(harness.getFeePot(indexId, address(assetC)), 2e6);
        assertEq(harness.getProtocolBalance(address(assetA)), 0);
    }

    function test_unknownIndex_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownIndex.selector, 0));
        harness.getIndex(0);

        vm.expectRevert(abi.encodeWithSelector(UnknownIndex.selector, 0));
        harness.getIndexAssets(0, 0, 1);
    }

    function _createIndex() internal returns (uint256 indexId) {
        address[] memory assets = new address[](3);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        assets[2] = address(assetC);

        uint256[] memory bundles = new uint256[](3);
        bundles[0] = 1 ether;
        bundles[1] = 2 ether;
        bundles[2] = 3e6;

        uint16[] memory mintFees = new uint16[](3);
        mintFees[0] = 10;
        mintFees[1] = 25;
        mintFees[2] = 40;

        uint16[] memory burnFees = new uint16[](3);
        burnFees[0] = 5;
        burnFees[1] = 15;
        burnFees[2] = 20;

        (indexId,) = harness.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundles,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 35
            })
        );
    }
}

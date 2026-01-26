// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexFacetV3} from "../../src/equalindex/EqualIndexFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "../../src/libraries/Errors.sol";

contract EqualIndexFacetHarness is EqualIndexFacetV3 {
    function setTreasury(address newTreasury) external {
        LibAppStorage.s().treasury = newTreasury;
    }

    function setAssetPool(address asset, uint256 pid, uint256 totalDeposits) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setDefaultPoolConfig() external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultPoolConfigSet = true;
        Types.PoolConfig storage cfg = store.defaultPoolConfig;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 9;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 500;
    }
}

contract EqualIndexPaginationTest is Test {
    EqualIndexFacetHarness public facet;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant INDEX_SCALE = 1e18;
    uint256 public constant INDEX_CREATION_FEE = 0.1 ether;
    uint256 public indexId;
    address public treasury = address(0xBEEF);

    function setUp() public {
        facet = new EqualIndexFacetHarness();
        tokenA = new MockERC20("TokenA", "TA", 18, INITIAL_SUPPLY);
        tokenB = new MockERC20("TokenB", "TB", 18, INITIAL_SUPPLY);
        tokenC = new MockERC20("TokenC", "TC", 18, INITIAL_SUPPLY);

        facet.setTreasury(treasury);
        _setIndexCreationFee(INDEX_CREATION_FEE);
        vm.deal(address(this), INDEX_CREATION_FEE);

        address[] memory assets = new address[](3);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        assets[2] = address(tokenC);

        uint256[] memory bundleAmounts = new uint256[](3);
        bundleAmounts[0] = 1 ether;
        bundleAmounts[1] = 2 ether;
        bundleAmounts[2] = 3 ether;

        uint16[] memory mintFees = new uint16[](3);
        mintFees[0] = 100;
        mintFees[1] = 200;
        mintFees[2] = 300;

        uint16[] memory burnFees = new uint16[](3);
        burnFees[0] = 150;
        burnFees[1] = 250;
        burnFees[2] = 350;

        facet.setAssetPool(address(tokenA), 1, INITIAL_SUPPLY);
        facet.setAssetPool(address(tokenB), 2, INITIAL_SUPPLY);
        facet.setAssetPool(address(tokenC), 3, INITIAL_SUPPLY);
        facet.setDefaultPoolConfig();

        (uint256 createdId,) = facet.createIndex{value: INDEX_CREATION_FEE}(
            EqualIndexBaseV3.CreateIndexParams({
                name: "Test Index",
                symbol: "TIDX",
                assets: assets,
                bundleAmounts: bundleAmounts,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 50
            })
        );

        indexId = createdId;
    }

    function _setTreasury(address newTreasury) internal {
        bytes32 base = keccak256("equal.lend.app.storage");
        bytes32 treasurySlot = bytes32(uint256(base) + 4);
        uint256 value = uint256(uint160(newTreasury));
        vm.store(address(facet), treasurySlot, bytes32(value));
    }

    function _setIndexCreationFee(uint256 newFee) internal {
        bytes32 base = keccak256("equal.lend.app.storage");
        bytes32 feeSlot = bytes32(uint256(base) + 9);
        vm.store(address(facet), feeSlot, bytes32(newFee));
    }

    function test_GetIndexAssetCountAndPagination() public {
        // Count should match bundle length
        uint256 count = facet.getIndexAssetCount(indexId);
        assertEq(count, 3, "Asset count should be 3");

        // First page (2 assets)
        (address[] memory assetsPage1, uint256[] memory bundlesPage1, uint16[] memory mintPage1, uint16[] memory burnPage1) =
            facet.getIndexAssets(indexId, 0, 2);

        assertEq(assetsPage1.length, 2, "Page 1 size");
        assertEq(bundlesPage1.length, 2, "Bundle page 1 size");
        assertEq(mintPage1.length, 2, "Mint fee page 1 size");
        assertEq(burnPage1.length, 2, "Burn fee page 1 size");

        // Second page (remaining asset)
        (address[] memory assetsPage2, uint256[] memory bundlesPage2,,) = facet.getIndexAssets(indexId, 2, 10);
        assertEq(assetsPage2.length, 1, "Page 2 size");
        assertEq(bundlesPage2.length, 1, "Bundle page 2 size");

        // Offset beyond end returns empty arrays
        (address[] memory emptyAssets,,,) = facet.getIndexAssets(indexId, 5, 1);
        assertEq(emptyAssets.length, 0, "No assets expected beyond end");

        // getIndex should return full arrays
        EqualIndexBaseV3.IndexView memory viewData = facet.getIndex(indexId);
        assertEq(viewData.assets.length, count, "Full view asset length");
        assertEq(viewData.bundleAmounts.length, count, "Full view bundle length");
        assertEq(viewData.mintFeeBps.length, count, "Full view mintFee length");
        assertEq(viewData.burnFeeBps.length, count, "Full view burnFee length");
    }

    function test_GetIndexAssets_LimitZeroReturnsRemainder() public {
        // Using limit = 0 should return remaining assets from offset
        (address[] memory assetsPage, uint256[] memory bundlesPage,,) = facet.getIndexAssets(indexId, 1, 0);
        assertEq(assetsPage.length, 2, "Limit 0 should return remaining assets");
        assertEq(bundlesPage.length, 2, "Limit 0 bundle length");
    }

    function test_GetIndexAssets_InvalidIndexReverts() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownIndex.selector, 999));
        facet.getIndexAssets(999, 0, 1);
    }

    function test_IndexTokenPaginationHelpers() public {
        EqualIndexBaseV3.IndexView memory viewData = facet.getIndex(indexId);
        IndexToken indexToken = IndexToken(viewData.token);

        address[] memory fullAssets = indexToken.assets();
        uint256[] memory fullBundles = indexToken.bundleAmounts();
        assertEq(fullAssets.length, 3, "Full assets length");
        assertEq(fullBundles.length, 3, "Full bundle length");

        // First two assets
        address[] memory pageAssets = indexToken.assetsPaginated(0, 2);
        uint256[] memory pageBundles = indexToken.bundleAmountsPaginated(0, 2);
        assertEq(pageAssets.length, 2, "Page assets length");
        assertEq(pageBundles.length, 2, "Page bundle length");
        assertEq(pageAssets[0], fullAssets[0], "First asset matches");
        assertEq(pageAssets[1], fullAssets[1], "Second asset matches");
        assertEq(pageBundles[0], fullBundles[0], "First bundle matches");
        assertEq(pageBundles[1], fullBundles[1], "Second bundle matches");

        // Remaining assets via limit = 0
        address[] memory pageAssetsRest = indexToken.assetsPaginated(1, 0);
        assertEq(pageAssetsRest.length, 2, "Remaining assets from offset 1");
    }

    function test_IndexTokenPreviewMintAndFlashLoanPaginated() public {
        EqualIndexBaseV3.IndexView memory viewData = facet.getIndex(indexId);
        IndexToken indexToken = IndexToken(viewData.token);

        uint256 units = 3 * INDEX_SCALE;

        (address[] memory fullAssets,,) = indexToken.previewMint(units);
        (address[] memory pageAssets, uint256[] memory requiredPage,) =
            indexToken.previewMintPaginated(units, 1, 1);

        assertEq(pageAssets.length, 1, "Single asset page");
        assertEq(pageAssets[0], fullAssets[1], "Paginated mint asset matches");

        // Flash loan preview pagination
        (address[] memory fullFlashAssets,,) = indexToken.previewFlashLoan(units);
        (address[] memory flashAssetsPage,,) = indexToken.previewFlashLoanPaginated(units, 2, 1);
        assertEq(flashAssetsPage.length, 1, "Flash loan single asset page");
        assertEq(flashAssetsPage[0], fullFlashAssets[2], "Paginated flash asset matches");

        // Required amount should be positive for the paginated asset
        assertGt(requiredPage[0], 0, "Required amount should be > 0");
    }

    function test_IndexTokenPreviewRedeemPaginated_NoSupply() public {
        EqualIndexBaseV3.IndexView memory viewData = facet.getIndex(indexId);
        IndexToken indexToken = IndexToken(viewData.token);

        uint256 units = 2 * INDEX_SCALE;

        // With zero supply, previewRedeem uses bundleAmounts * units
        (address[] memory fullAssets, uint256[] memory fullNetOut,) = indexToken.previewRedeem(units);
        (address[] memory pageAssets, uint256[] memory pageNetOut,) =
            indexToken.previewRedeemPaginated(units, 1, 2);

        assertEq(pageAssets.length, 2, "Redeem page length");
        assertEq(pageAssets[0], fullAssets[1], "First paginated redeem asset matches");
        assertEq(pageAssets[1], fullAssets[2], "Second paginated redeem asset matches");
        assertEq(pageNetOut[0], fullNetOut[1], "First paginated redeem amount matches");
        assertEq(pageNetOut[1], fullNetOut[2], "Second paginated redeem amount matches");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FlashLoanRepayer {
    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata
    ) external {
        for (uint256 i = 0; i < assets.length; i++) {
            MockERC20(assets[i]).transfer(msg.sender, amounts[i] + fees[i]);
        }
    }
}

contract EqualIndexFlashLoanFeeSplitHarness is EqualIndexActionsFacetV3 {
    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits + totalDeposits;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setIndex(
        uint256 indexId,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16 flashFeeBps,
        uint256 totalUnits
    ) external {
        EqualIndexStorage storage es = s();
        if (es.indexCount <= indexId) {
            es.indexCount = indexId + 1;
        }
        Index storage idx = es.indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = new uint16[](assets.length);
        idx.burnFeeBps = new uint16[](assets.length);
        idx.flashFeeBps = flashFeeBps;
        idx.totalUnits = totalUnits;
        idx.token = address(0);
        idx.paused = false;
    }

    function setVaultBalance(uint256 indexId, address asset, uint256 amount) external {
        s().vaultBalances[indexId][asset] = amount;
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function feeIndexRemainder(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndexRemainder;
    }

    function feePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }
}

contract EqualIndexFlashLoanFeeSplitTest is Test {
    uint256 private constant PID = 1;
    uint256 private constant INDEX_ID = 0;

    function test_flashLoanFeeSplit_routesToPoolFeeIndexAndPot() public {
        (EqualIndexFlashLoanFeeSplitHarness facet, MockERC20 asset) = _setup();
        FlashLoanRepayer borrower = new FlashLoanRepayer();
        asset.mint(address(borrower), 10 ether);

        uint256 feeIndexBefore = facet.feeIndex(PID);
        uint256 remainderBefore = facet.feeIndexRemainder(PID);
        uint256 potBefore = facet.feePot(INDEX_ID, address(asset));

        facet.flashLoan(INDEX_ID, 1 ether, address(borrower), "");

        uint256 potAfter = facet.feePot(INDEX_ID, address(asset));
        assertEq(potAfter - potBefore, 9 ether);

        uint256 feeIndexAfter = facet.feeIndex(PID);
        uint256 remainderAfter = facet.feeIndexRemainder(PID);
        uint256 scaledBefore = feeIndexBefore * 1_000 ether + remainderBefore;
        uint256 scaledAfter = feeIndexAfter * 1_000 ether + remainderAfter;
        uint256 fee = 10 ether;
        uint256 poolShare = fee / 10;
        uint16 treasuryBps = LibAppStorage.treasurySplitBps(LibAppStorage.s());
        uint256 activeBps = LibAppStorage.activeCreditSplitBps(LibAppStorage.s());
        address treasuryAddr = LibAppStorage.treasuryAddress(LibAppStorage.s());
        uint256 toTreasury = treasuryAddr != address(0) ? (poolShare * treasuryBps) / 10_000 : 0;
        uint256 toActive = (poolShare * activeBps) / 10_000;
        uint256 toIndex = poolShare - toTreasury - toActive;
        assertEq(scaledAfter - scaledBefore, toIndex * 1e18);
    }

    function _setup() internal returns (EqualIndexFlashLoanFeeSplitHarness facet, MockERC20 asset) {
        asset = new MockERC20("Asset", "AST", 18, 1_000_000 ether);
        facet = new EqualIndexFlashLoanFeeSplitHarness();

        facet.seedPool(PID, address(asset), 1_000 ether);
        facet.setAssetToPoolId(address(asset), PID);

        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        facet.setIndex(INDEX_ID, assets, bundle, 1000, 1 ether);

        uint256 vaultBalance = 100 ether;
        facet.setVaultBalance(INDEX_ID, address(asset), vaultBalance);
        asset.transfer(address(facet), vaultBalance);
    }
}

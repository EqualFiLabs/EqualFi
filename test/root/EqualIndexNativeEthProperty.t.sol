// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexBaseV3, IEqualIndexFlashReceiver} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {UnexpectedMsgValue} from "../../src/libraries/Errors.sol";

contract EqualIndexNativeHarness is EqualIndexActionsFacetV3 {
    function initIndex(
        uint256 indexId,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16[] memory mintFeeBps,
        uint16[] memory burnFeeBps,
        uint16 flashFeeBps,
        address token
    ) external {
        Index storage idx = s().indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = mintFeeBps;
        idx.burnFeeBps = burnFeeBps;
        idx.flashFeeBps = flashFeeBps;
        idx.token = token;
        if (s().indexCount <= indexId) {
            s().indexCount = indexId + 1;
        }
    }

    function setAssetPool(address asset, uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setTreasury(address treasury, uint16 shareBps) external {
        LibAppStorage.s().treasury = treasury;
        LibAppStorage.s().treasuryShareConfigured = true;
        LibAppStorage.s().treasuryShareBps = shareBps;
    }

    function setActiveCreditShare(uint16 shareBps) external {
        LibAppStorage.s().activeCreditShareConfigured = true;
        LibAppStorage.s().activeCreditShareBps = shareBps;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function mintBurnFeeShareBps() external view returns (uint16) {
        return _mintBurnFeeIndexShareBps();
    }

    function poolFeeShareBps() external view returns (uint16) {
        return _poolFeeShareBps();
    }

    receive() external payable {}
}

contract NativeIndexFlashReceiver is IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external override {
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(0)) {
                uint256 repay = amounts[i] + feeAmounts[i];
                (bool success,) = msg.sender.call{value: repay}("");
                require(success, "repay failed");
            }
        }
    }

    receive() external payable {}
}

contract EqualIndexNativeEthPropertyTest is Test {
    EqualIndexNativeHarness internal facet;
    IndexToken internal indexToken;
    NativeIndexFlashReceiver internal receiver;

    address internal treasury = address(0xBEEF);
    uint256 internal constant INDEX_ID = 1;
    uint256 internal constant SCALE = 1e18;
    uint16 internal constant TREASURY_BPS = 2000; // 20%

    function setUp() public {
        facet = new EqualIndexNativeHarness();
        receiver = new NativeIndexFlashReceiver();

        address[] memory assets = new address[](1);
        assets[0] = address(0);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 10 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 100; // 1%
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 50; // 0.5%

        indexToken = new IndexToken(
            "Native Index",
            "NIDX",
            address(facet),
            assets,
            bundleAmounts,
            0,
            INDEX_ID
        );

        facet.initIndex(INDEX_ID, assets, bundleAmounts, mintFees, burnFees, 100, address(indexToken));
        facet.setAssetPool(address(0), 1, 0, 0);
        facet.setTreasury(treasury, TREASURY_BPS);
        facet.setActiveCreditShare(0);
        facet.setNativeTrackedTotal(0);

        vm.deal(address(facet), 100 ether);
        vm.deal(address(receiver), 5 ether);
    }

    receive() external payable {}

    /// Feature: native-eth-support, Property 10: EqualIndex Native ETH Correctness
    function test_nativeMintBurnAndMsgValueGuard() public {
        uint256 units = 1 * SCALE;
        uint256 need = 10 ether;
        uint256 fee = (need * 100) / 10_000;
        uint256 poolShare = (fee * facet.mintBurnFeeShareBps()) / 10_000;
        uint256 potFee = fee - poolShare;
        uint256 toTreasury = (poolShare * TREASURY_BPS) / 10_000;
        uint256 total = need + fee;

        vm.deal(address(this), total);

        uint256 minted = facet.mint{value: total}(INDEX_ID, units, address(this));
        assertEq(minted, units);
        assertEq(facet.getVaultBalance(INDEX_ID, address(0)), need);
        assertEq(facet.getFeePot(INDEX_ID, address(0)), potFee);
        assertEq(treasury.balance, toTreasury);
        assertEq(facet.nativeTrackedTotal(), need + fee - toTreasury);

        uint256 vaultBefore = facet.getVaultBalance(INDEX_ID, address(0));
        uint256 potBefore = facet.getFeePot(INDEX_ID, address(0));
        uint256 supplyBefore = indexToken.totalSupply();
        uint256 nativeTrackedBefore = facet.nativeTrackedTotal();
        uint256 userBalanceBefore = address(this).balance;

        uint256 navShare = Math.mulDiv(vaultBefore, units, supplyBefore);
        uint256 potShare = Math.mulDiv(potBefore, units, supplyBefore);
        uint256 gross = navShare + potShare;
        uint256 burnFee = Math.mulDiv(gross, 50, 10_000);
        uint256 burnPoolShare = Math.mulDiv(burnFee, facet.mintBurnFeeShareBps(), 10_000);
        uint256 burnTreasury = Math.mulDiv(burnPoolShare, TREASURY_BPS, 10_000);
        uint256 payout = gross - burnFee;

        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1));
        facet.burn{value: 1}(INDEX_ID, units, address(this));

        facet.burn(INDEX_ID, units, address(this));
        assertEq(address(this).balance - userBalanceBefore, payout, "payout");
        assertEq(facet.getVaultBalance(INDEX_ID, address(0)), vaultBefore - navShare, "vault balance");
        assertEq(facet.nativeTrackedTotal(), nativeTrackedBefore - payout - burnTreasury, "native tracked");
    }

    /// Feature: native-eth-support, Property 10: EqualIndex Native ETH Correctness
    function test_nativeFlashLoanFeeAccounting() public {
        uint256 units = 1 * SCALE;
        facet.mint(INDEX_ID, units, address(this));

        uint256 vaultBefore = facet.getVaultBalance(INDEX_ID, address(0));
        uint256 totalSupply = indexToken.totalSupply();
        uint256 loanAmount = Math.mulDiv(vaultBefore, units, totalSupply);
        uint256 fee = (loanAmount * 100) / 10_000; // flash fee bps
        uint256 poolShare = (fee * facet.poolFeeShareBps()) / 10_000;
        uint256 toTreasury = (poolShare * TREASURY_BPS) / 10_000;

        uint256 treasuryBefore = treasury.balance;
        uint256 nativeTrackedBefore = facet.nativeTrackedTotal();

        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1));
        facet.flashLoan{value: 1}(INDEX_ID, units, address(receiver), "");

        facet.flashLoan(INDEX_ID, units, address(receiver), "");

        assertEq(treasury.balance - treasuryBefore, toTreasury, "treasury fee");
        assertEq(facet.nativeTrackedTotal(), nativeTrackedBefore + fee - toTreasury, "native tracked");
    }
}

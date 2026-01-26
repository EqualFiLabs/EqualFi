// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexNativeIntegrationHarness is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3 {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setDefaultPoolConfig(Types.PoolConfig memory config) external {
        Types.PoolConfig storage target = LibAppStorage.s().defaultPoolConfig;
        target.rollingApyBps = config.rollingApyBps;
        target.depositorLTVBps = config.depositorLTVBps;
        target.maintenanceRateBps = config.maintenanceRateBps;
        target.flashLoanFeeBps = config.flashLoanFeeBps;
        target.flashLoanAntiSplit = config.flashLoanAntiSplit;
        target.minDepositAmount = config.minDepositAmount;
        target.minLoanAmount = config.minLoanAmount;
        target.minTopupAmount = config.minTopupAmount;
        target.isCapped = config.isCapped;
        target.depositCap = config.depositCap;
        target.maxUserCount = config.maxUserCount;
        target.aumFeeMinBps = config.aumFeeMinBps;
        target.aumFeeMaxBps = config.aumFeeMaxBps;
        target.borrowFee = config.borrowFee;
        target.repayFee = config.repayFee;
        target.withdrawFee = config.withdrawFee;
        target.flashFee = config.flashFee;
        target.closeRollingFee = config.closeRollingFee;
        delete target.fixedTermConfigs;
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        LibAppStorage.s().assetToPoolId[underlying] = pid;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function setTreasury(address treasury, uint16 treasuryShareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareBps = treasuryShareBps;
        store.treasuryShareConfigured = true;
    }

    function setActiveCreditShare(uint16 activeShareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.activeCreditShareBps = activeShareBps;
        store.activeCreditShareConfigured = true;
    }

    function setMintBurnFeeIndexShare(uint16 shareBps) external {
        s().mintBurnFeeIndexShareBps = shareBps;
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }
}

contract EqualIndexNativeEthIntegrationTest is Test {
    EqualIndexNativeIntegrationHarness internal facet;
    MockERC20 internal tokenB;

    address internal user = address(0xBEEF);
    uint256 internal constant NATIVE_POOL = 1;
    uint256 internal constant TOKEN_POOL = 2;

    function setUp() public {
        facet = new EqualIndexNativeIntegrationHarness();
        facet.setOwner(address(this));
        facet.setTreasury(address(0), 0);
        facet.setActiveCreditShare(0);
        facet.setMintBurnFeeIndexShare(4000);
        facet.setDefaultPoolConfig(_defaultConfig());

        tokenB = new MockERC20("TokenB", "TB", 18, 0);
    }

    /// Feature: native-eth-support, Integration 13.3: EqualIndex native ETH flow
    function testIntegration_equalIndexNativeMintBurn() public {
        facet.seedPool(NATIVE_POOL, address(0), 100 ether, 100 ether);
        facet.seedPool(TOKEN_POOL, address(tokenB), 100 ether, 100 ether);
        facet.setNativeTrackedTotal(100 ether);

        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = address(tokenB);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 1 ether;
        bundleAmounts[1] = 2 ether;
        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 100;
        mintFees[1] = 100;
        uint16[] memory burnFees = new uint16[](2);
        burnFees[0] = 50;
        burnFees[1] = 50;
        uint16 feeIndexShareBps = 4000;

        EqualIndexBaseV3.CreateIndexParams memory params = EqualIndexBaseV3.CreateIndexParams({
            name: "Native Index",
            symbol: "NIDX",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeBps: mintFees,
            burnFeeBps: burnFees,
            flashFeeBps: 0
        });

        (uint256 indexId, address tokenAddr) = facet.createIndex(params);
        IndexToken idxToken = IndexToken(tokenAddr);

        uint256 units = LibEqualIndex.INDEX_SCALE;
        uint256 nativeTotal = bundleAmounts[0] + ((bundleAmounts[0] * mintFees[0]) / 10_000);
        vm.deal(address(facet), 100 ether + nativeTotal);

        tokenB.mint(address(this), 1_000 ether);
        tokenB.approve(address(facet), type(uint256).max);

        facet.mint(indexId, units, user);

        assertEq(facet.getVaultBalance(indexId, address(0)), bundleAmounts[0], "native vault balance");
        assertEq(facet.getVaultBalance(indexId, address(tokenB)), bundleAmounts[1], "token vault balance");

        vm.prank(user);
        facet.burn(indexId, units, user);

        uint256 nativeMintFee = Math.mulDiv(bundleAmounts[0], mintFees[0], 10_000);
        uint256 nativeMintPoolShare = Math.mulDiv(nativeMintFee, feeIndexShareBps, 10_000);
        uint256 nativeMintPot = nativeMintFee - nativeMintPoolShare;
        uint256 nativeBurnGross = bundleAmounts[0] + nativeMintPot;
        uint256 nativeBurnFee = Math.mulDiv(nativeBurnGross, burnFees[0], 10_000);
        uint256 nativeBurnPoolShare = Math.mulDiv(nativeBurnFee, feeIndexShareBps, 10_000);
        uint256 nativeBurnPot = nativeBurnFee - nativeBurnPoolShare;

        uint256 tokenMintFee = Math.mulDiv(bundleAmounts[1], mintFees[1], 10_000);
        uint256 tokenMintPoolShare = Math.mulDiv(tokenMintFee, feeIndexShareBps, 10_000);
        uint256 tokenMintPot = tokenMintFee - tokenMintPoolShare;
        uint256 tokenBurnGross = bundleAmounts[1] + tokenMintPot;
        uint256 tokenBurnFee = Math.mulDiv(tokenBurnGross, burnFees[1], 10_000);
        uint256 tokenBurnPoolShare = Math.mulDiv(tokenBurnFee, feeIndexShareBps, 10_000);
        uint256 tokenBurnPot = tokenBurnFee - tokenBurnPoolShare;

        assertEq(idxToken.totalSupply(), 0, "index burned");
        assertEq(facet.getVaultBalance(indexId, address(0)), 0, "native vault cleared");
        assertEq(facet.getVaultBalance(indexId, address(tokenB)), 0, "token vault cleared");
        assertEq(facet.getFeePot(indexId, address(0)), nativeBurnPot, "native fee pot after burn");
        assertEq(facet.getFeePot(indexId, address(tokenB)), tokenBurnPot, "token fee pot after burn");
    }

    function _defaultConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 0;
        cfg.flashLoanFeeBps = 0;
        cfg.rollingApyBps = 0;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 0;
    }
}

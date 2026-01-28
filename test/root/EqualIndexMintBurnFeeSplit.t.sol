// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexFacetV3} from "../../src/equalindex/EqualIndexFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract MintBurnFeeSplitHarness is EqualIndexFacetV3 {
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
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = 1e18;
        p.maintenanceIndex = 1e18;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function getTreasurySplitBps() external view returns (uint16) {
        return LibAppStorage.treasurySplitBps(LibAppStorage.s());
    }

    function getActiveCreditSplitBps() external view returns (uint16) {
        return LibAppStorage.activeCreditSplitBps(LibAppStorage.s());
    }

    function getTreasuryAddress() external view returns (address) {
        return LibAppStorage.treasuryAddress(LibAppStorage.s());
    }

    function setIndexCreationFee(uint256 fee) external {
        LibAppStorage.s().indexCreationFee = fee;
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function getPoolFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function getMintBurnFeeIndexShareBps() external view returns (uint16) {
        return _mintBurnFeeIndexShareBps();
    }

    function getPoolFeeShareBps() external view returns (uint16) {
        return _poolFeeShareBps();
    }
}

/// @notice Tests for EqualIndex mint/burn fee split (pool share + fee pot).
contract EqualIndexMintBurnFeeSplitTest is Test {
    MintBurnFeeSplitHarness internal facet;
    MockERC20 internal token;
    address internal treasury = address(0xBEEF);
    uint256 internal indexId;
    uint256 internal poolId = 1;

    uint16 internal constant MINT_FEE_BPS = 100; // 1%
    uint16 internal constant BURN_FEE_BPS = 100; // 1%
    uint16 internal constant FLASH_FEE_BPS = 30; // 0.3%

    function setUp() public {
        facet = new MintBurnFeeSplitHarness();
        token = new MockERC20("Token", "TOK", 18, 10_000 ether);

        facet.setDefaultPoolConfig(_validPoolConfig());
        facet.setTreasury(treasury);
        facet.setIndexCreationFee(0); // Free creation for tests
        facet.setTimelock(address(this));
        facet.setAssetToPoolId(address(token), poolId);
        facet.seedPool(poolId, address(token), 1_000 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = MINT_FEE_BPS;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = BURN_FEE_BPS;

        (indexId,) = facet.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "Test",
                symbol: "TST",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: FLASH_FEE_BPS
            })
        );
    }

    function _validPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.rollingApyBps = 500;
    }

    function _splitProtocol(uint256 amount)
        internal
        view
        returns (uint256 toTreasury, uint256 toActive, uint256 toIndex)
    {
        uint16 treasuryBps = facet.getTreasurySplitBps();
        uint16 activeBps = facet.getActiveCreditSplitBps();
        address treasuryAddr = facet.getTreasuryAddress();
        toTreasury = treasuryAddr != address(0) ? (amount * treasuryBps) / 10_000 : 0;
        toActive = (amount * activeBps) / 10_000;
        toIndex = amount - toTreasury - toActive;
    }

    function test_defaultMintBurnFeeIndexShareBps() public {
        // Default should be 4000 (40%)
        assertEq(facet.getMintBurnFeeIndexShareBps(), 4000, "default mintBurnFeeIndexShareBps should be 4000");
    }

    function test_mintFeeSplit_twoWay() public {
        // Mint 1 unit, fee = 0.01 ether (1% of 1 ether)
        // Default split: 40% pool share, remainder to fee pot
        uint256 units = LibEqualIndex.INDEX_SCALE;
        uint256 fee = 0.01 ether;

        uint256 feeIndexBefore = facet.getPoolFeeIndex(poolId);
        uint256 treasuryBefore = token.balanceOf(treasury);

        token.approve(address(facet), 1.01 ether);
        facet.mint(indexId, units, address(this));

        uint256 feeIndexAfter = facet.getPoolFeeIndex(poolId);
        uint256 treasuryAfter = token.balanceOf(treasury);
        uint256 feePot = facet.getFeePot(indexId, address(token));

        // Calculate expected splits
        uint256 poolShare = (fee * 4000) / 10_000; // 40% = 0.004 ether
        uint256 potShare = fee - poolShare; // 0.006 ether
        (uint256 treasuryShare,,) = _splitProtocol(poolShare);

        // Fee index should have increased
        assertGt(feeIndexAfter, feeIndexBefore, "Fee index should increase");

        // Treasury should receive pool share split
        assertApproxEqAbs(treasuryAfter - treasuryBefore, treasuryShare, 1, "Treasury receives pool share");

        // Fee pot should receive its share
        assertApproxEqAbs(feePot, potShare, 1, "Fee pot receives its share");
    }

    function test_burnFeeSplit_twoWay() public {
        // First mint
        token.approve(address(facet), 1.01 ether);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        // Now burn
        IndexToken idxToken = IndexToken(facet.getIndex(indexId).token);
        idxToken.approve(address(facet), LibEqualIndex.INDEX_SCALE);

        uint256 feeIndexBefore = facet.getPoolFeeIndex(poolId);
        uint256 treasuryBefore = token.balanceOf(treasury);

        facet.burn(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        uint256 feeIndexAfter = facet.getPoolFeeIndex(poolId);
        uint256 treasuryAfter = token.balanceOf(treasury);

        // Fee index should increase from burn fee
        assertGt(feeIndexAfter, feeIndexBefore, "Fee index should increase on burn");

        // Treasury should receive pool share split from burn fee
        assertGt(treasuryAfter, treasuryBefore, "Treasury receives burn fee pool share");
    }

    function test_setMintBurnFeeIndexShareBps() public {
        // Change to 50%
        facet.setMintBurnFeeIndexShareBps(5000);
        assertEq(facet.getMintBurnFeeIndexShareBps(), 5000, "Should update to 5000");

        // Mint and verify new split
        uint256 fee = 0.01 ether;
        uint256 feeIndexBefore = facet.getPoolFeeIndex(poolId);

        token.approve(address(facet), 1.01 ether);
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        uint256 feeIndexAfter = facet.getPoolFeeIndex(poolId);
        uint256 feePot = facet.getFeePot(indexId, address(token));

        // With 50% fee index share:
        uint256 poolShare = (fee * 5000) / 10_000; // 0.005 ether
        uint256 expectedPot = fee - poolShare;

        assertGt(feeIndexAfter, feeIndexBefore, "Fee index should increase");
        assertApproxEqAbs(feePot, expectedPot, 1, "Fee pot reflects new config");
    }

    function test_setMintBurnFeeIndexShareBps_onlyTimelock() public {
        address notTimelock = address(0x1234);
        vm.prank(notTimelock);
        vm.expectRevert(Unauthorized.selector);
        facet.setMintBurnFeeIndexShareBps(5000);
    }

    function test_setMintBurnFeeIndexShareBps_maxValidation() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "mintBurnFeeIndexShareBps too high"));
        facet.setMintBurnFeeIndexShareBps(10001);
    }

    function test_mintBurnAndFlashUseDifferentConfigs() public {
        // Set different values for each config
        facet.setMintBurnFeeIndexShareBps(8000); // 80% for mint/burn
        facet.setPoolFeeShareBps(1000); // 10% for flash (default)

        assertEq(facet.getMintBurnFeeIndexShareBps(), 8000, "mintBurn config should be 8000");
        assertEq(facet.getPoolFeeShareBps(), 1000, "flash config should be 1000");

        // Configs are independent
        assertNotEq(
            facet.getMintBurnFeeIndexShareBps(),
            facet.getPoolFeeShareBps(),
            "Configs should be independent"
        );
    }

    function test_mintFeeSplit_routesPoolShareWhenPoolMapped() public {
        // Create a new token with a pool mapping
        MockERC20 newToken = new MockERC20("New", "NEW", 18, 10_000 ether);
        facet.setAssetToPoolId(address(newToken), 2);
        facet.seedPool(2, address(newToken), 1_000 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(newToken);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = MINT_FEE_BPS;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = BURN_FEE_BPS;

        (uint256 newIndexId,) = facet.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "New",
                symbol: "NEW",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: FLASH_FEE_BPS
            })
        );

        newToken.approve(address(facet), 1.01 ether);
        facet.mint(newIndexId, LibEqualIndex.INDEX_SCALE, address(this));

        // Should succeed and fee pot should have received its share
        assertGt(facet.getFeePot(newIndexId, address(newToken)), 0, "Fee pot should receive share");
    }
}

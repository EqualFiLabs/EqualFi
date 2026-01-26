// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract EqualIndexPoolCreationHarness is EqualIndexAdminFacetV3 {
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
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
    }

    function getPoolUnderlying(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].underlying;
    }

    function getAssetPoolId(address asset) external view returns (uint256) {
        return LibAppStorage.s().assetToPoolId[asset];
    }
}

contract EqualIndexPoolCreationPropertyTest is Test {
    EqualIndexPoolCreationHarness internal facet;

    function setUp() public {
        facet = new EqualIndexPoolCreationHarness();
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_validPoolConfig());
    }

    function testFuzz_poolExistenceInvariant(address assetA, address assetB) public {
        vm.assume(assetA != address(0));
        vm.assume(assetB != address(0));
        vm.assume(assetA != assetB);

        facet.setAssetToPoolId(assetA, 1);

        EqualIndexBaseV3.CreateIndexParams memory p = _paramsForAssets(assetA, assetB);
        vm.expectRevert(abi.encodeWithSelector(NoPoolForAsset.selector, assetB));
        facet.createIndex(p);
    }

    function testFuzz_indexPoolAutoCreation(address assetA, address assetB) public {
        vm.assume(assetA != address(0));
        vm.assume(assetB != address(0));
        vm.assume(assetA != assetB);

        facet.setAssetToPoolId(assetA, 1);
        facet.setAssetToPoolId(assetB, 2);

        EqualIndexBaseV3.CreateIndexParams memory p = _paramsForAssets(assetA, assetB);
        (uint256 indexId, address token) = facet.createIndex(p);

        uint256 poolId = facet.getIndexPoolId(indexId);
        assertGt(poolId, 0);
        assertEq(facet.getPoolUnderlying(poolId), token);
        assertEq(facet.getAssetPoolId(token), poolId);
    }

    function _paramsForAssets(address assetA, address assetB)
        internal
        pure
        returns (EqualIndexBaseV3.CreateIndexParams memory p)
    {
        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory bundle = new uint256[](2);
        bundle[0] = 1 ether;
        bundle[1] = 2 ether;
        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 0;
        mintFees[1] = 0;
        uint16[] memory burnFees = new uint16[](2);
        burnFees[0] = 0;
        burnFees[1] = 0;
        p = EqualIndexBaseV3.CreateIndexParams({
            name: "IDX",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundle,
            mintFeeBps: mintFees,
            burnFeeBps: burnFees,
            flashFeeBps: 0
        });
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
}

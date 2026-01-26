// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexAdminGasHarness is EqualIndexAdminFacetV3 {
    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
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
}

contract EqualIndexAdminGasTest is Test {
    EqualIndexAdminGasHarness internal facet;
    MockERC20 internal token;
    uint256 internal indexId;

    function setUp() public {
        facet = new EqualIndexAdminGasHarness();
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        _setOwner(address(this));
        _setTimelock(address(this));
        facet.setDefaultPoolConfig(_validPoolConfig());
        facet.setAssetToPoolId(address(token), 1);

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 100;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 100;

        (indexId,) = facet.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 50
            })
        );
    }

    function test_gas_SetIndexFees() public {
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 200;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 200;

        vm.resumeGasMetering();
        facet.setIndexFees(indexId, mintFees, burnFees, 60);
    }

    function _setOwner(address newOwner) internal {
        bytes32 slot = keccak256("diamond.standard.diamond.storage");
        bytes32 ownerSlot = bytes32(uint256(slot) + 3);
        vm.store(address(facet), ownerSlot, bytes32(uint256(uint160(newOwner))));
    }

    function _setTimelock(address newTimelock) internal {
        bytes32 base = keccak256("equal.lend.app.storage");
        bytes32 timelockSlot = bytes32(uint256(base) + 3);
        uint256 value = uint256(uint160(newTimelock)) << 8;
        vm.store(address(facet), timelockSlot, bytes32(value));
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

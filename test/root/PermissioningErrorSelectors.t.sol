// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {InsufficientPoolCreationFee, InsufficientIndexCreationFee} from "../../src/libraries/Errors.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";

contract PoolHarness is PoolManagementFacet {
    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
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

contract IndexAdminHarness is EqualIndexAdminFacetV3 {
    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }
}

contract PermissioningErrorSelectorsTest is Test {
    PoolHarness internal pool;
    IndexAdminHarness internal indexFacet;
    MockERC20 internal asset;
    address internal timelock = address(0xBEEF);

    function setUp() public {
        pool = new PoolHarness();
        indexFacet = new IndexAdminHarness();
        asset = new MockERC20("Asset", "AST", 18, 0);
    }

    function _setLegacyTimelock(address target) internal {
        bytes32 appSlot = keccak256("equal.lend.app.storage");
        bytes32 diamondSlot = keccak256("diamond.standard.diamond.storage");
        // contractOwner slot offset used in prior tests (diamond slot + 3)
        uint256 ownerSlot = uint256(diamondSlot) + 3;
        vm.store(target, bytes32(ownerSlot), bytes32(uint256(uint160(timelock))));
        // legacy timelock slot (app storage + 8)
        uint256 timelockSlot = uint256(appSlot) + 8;
        vm.store(target, bytes32(timelockSlot), bytes32(uint256(uint160(timelock))));
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

    function _validIndexParams() internal pure returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        address[] memory assets = new address[](1);
        assets[0] = address(0x1234);
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = 1 ether;
        uint16[] memory mint = new uint16[](1);
        mint[0] = 0;
        uint16[] memory burn = new uint16[](1);
        burn[0] = 0;
        uint16 flash = 0;
        p = EqualIndexBaseV3.CreateIndexParams({
            name: "Idx",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundles,
            mintFeeBps: mint,
            burnFeeBps: burn,
            flashFeeBps: flash
        });
    }

    function testPoolPermissionlessDisabledRevertsWithSelector() public {
        pool.setTreasury(address(0xCAFE));
        pool.setPoolCreationFee(0); // permissionless disabled
        Types.PoolConfig memory cfg = _validPoolConfig();
        pool.setDefaultPoolConfig(cfg);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolCreationFee.selector, 1, 0));
        pool.initPool(address(asset));
    }

    function testIndexPermissionlessWrongFeeRevertsWithSelector() public {
        // Set fee in legacy slot (app storage + 9 used by LibAppStorage.indexCreationFee fallback)
        bytes32 appSlot = keccak256("equal.lend.app.storage");
        uint256 feeSlot = uint256(appSlot) + 9;
        vm.store(address(indexFacet), bytes32(feeSlot), bytes32(uint256(0.5 ether)));
        EqualIndexBaseV3.CreateIndexParams memory p = _validIndexParams();
        indexFacet.setAssetToPoolId(p.assets[0], 1);
        vm.expectRevert(abi.encodeWithSelector(InsufficientIndexCreationFee.selector, 0.5 ether, 0));
        indexFacet.createIndex(p);
    }
}

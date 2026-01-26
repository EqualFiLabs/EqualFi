// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {
    InsufficientPoolCreationFee,
    InvalidLTVRatio,
    PermissionlessPoolAlreadyInitialized
} from "../../src/libraries/Errors.sol";

contract PoolManagementHarness is PoolManagementFacet {
    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMaxMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().maxMaintenanceRateBps = rate;
    }

    function setDefaultMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().defaultMaintenanceRateBps = rate;
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

    function getPoolUnderlying(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].underlying;
    }

    function getPoolConfig(uint256 pid) external view returns (Types.PoolConfig memory) {
        return LibAppStorage.s().pools[pid].poolConfig;
    }

    function getPermissionlessPoolPid(address underlying) external view returns (uint256) {
        return LibAppStorage.s().permissionlessPoolForToken[underlying];
    }

    function getAssetPoolId(address underlying) external view returns (uint256) {
        return LibAppStorage.s().assetToPoolId[underlying];
    }
    
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }
}

contract PoolManagementFacetTest is Test {
    PoolManagementHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xBEEF);
    
    Types.PoolConfig internal validConfig;

    function setUp() public {
        facet = new PoolManagementHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        facet.setOwner(address(this)); // Treat test contract as gov to bypass permissionless fee gate
        
        facet.setTreasury(treasury);
        facet.setPoolCreationFee(0); // Default to free for ease

        // valid config
        validConfig.minDepositAmount = 1 ether;
        validConfig.minLoanAmount = 1 ether;
        validConfig.minTopupAmount = 0.1 ether;
        validConfig.aumFeeMinBps = 100;
        validConfig.aumFeeMaxBps = 500;
        validConfig.depositorLTVBps = 8000;
        validConfig.maintenanceRateBps = 50; // 0.5%
        validConfig.flashLoanFeeBps = 10;
        validConfig.rollingApyBps = 500;
        // fixed terms empty by default
        facet.setDefaultPoolConfig(validConfig);
    }

    function testInitPoolSuccess() public {
        facet.initPool(1, address(underlying), validConfig);
        
        address poolUnderlying = facet.getPoolUnderlying(1);
        Types.PoolConfig memory config = facet.getPoolConfig(1);
        
        assertEq(poolUnderlying, address(underlying));
        assertEq(config.minDepositAmount, 1 ether);
        assertEq(facet.getAssetPoolId(address(underlying)), 1);
    }

    function testInitPoolWithFee() public {
        uint256 fee = 0.1 ether;
        facet.setPoolCreationFee(fee);
        
        address payer = address(0xB0B);
        vm.deal(payer, 1 ether);
        
        uint256 balBefore = treasury.balance;
        vm.prank(payer);
        facet.initPool{value: fee}(address(underlying));
        
        assertEq(treasury.balance - balBefore, fee);
    }

    function testPermissionlessDuplicateUnderlyingReverts() public {
        facet.setOwner(address(0xCAFE));
        uint256 fee = 0.1 ether;
        facet.setPoolCreationFee(fee);

        address payer = address(0xB0B);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        facet.initPool{value: fee}(address(underlying));

        assertEq(facet.getPermissionlessPoolPid(address(underlying)), 1);

        address payer2 = address(0xB0B2);
        vm.deal(payer2, 1 ether);
        vm.prank(payer2);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionlessPoolAlreadyInitialized.selector,
                address(underlying),
                1
            )
        );
        facet.initPool{value: fee}(address(underlying));
    }

    function testGovBypassAllowsDuplicateUnderlying() public {
        facet.setOwner(address(this));
        facet.initPool(1, address(underlying), validConfig);
        facet.initPool(2, address(underlying), validConfig);
        assertEq(facet.getPoolUnderlying(2), address(underlying));
        assertEq(facet.getAssetPoolId(address(underlying)), 2);
    }

    function testInitPoolInsufficientFee() public {
        uint256 fee = 0.1 ether;
        facet.setPoolCreationFee(fee);
        address payer = address(0xB0B);
        vm.deal(payer, fee);
        
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolCreationFee.selector, fee, fee - 1));
        facet.initPool{value: fee - 1}(address(underlying));
    }

    function testInitPoolAlreadyExists() public {
        facet.initPool(1, address(underlying), validConfig);
        
        vm.expectRevert(); // PoolAlreadyExists
        facet.initPool(1, address(underlying), validConfig);
    }

    function testInitPoolAllowsNativeUnderlying() public {
        facet.initPool(1, address(0), validConfig);
        assertEq(facet.getPoolUnderlying(1), address(0));
        assertEq(facet.getAssetPoolId(address(0)), 1);
    }

    function testInitPoolInvalidThresholds() public {
        Types.PoolConfig memory config = validConfig;
        config.minDepositAmount = 0;
        vm.expectRevert(); // InvalidMinimumThreshold
        facet.initPool(1, address(underlying), config);
    }

    function testInitPoolInvalidAumFees() public {
        Types.PoolConfig memory config = validConfig;
        config.aumFeeMinBps = 600;
        config.aumFeeMaxBps = 500;
        vm.expectRevert(); // InvalidAumFeeBounds
        facet.initPool(1, address(underlying), config);
    }

    function testInitPoolInvalidLTV() public {
        Types.PoolConfig memory config = validConfig;
        config.depositorLTVBps = 10001;
        vm.expectRevert(InvalidLTVRatio.selector);
        facet.initPool(1, address(underlying), config);
    }

    function testInitPoolZeroLTV() public {
        Types.PoolConfig memory config = validConfig;
        config.depositorLTVBps = 0;
        vm.expectRevert(InvalidLTVRatio.selector);
        facet.initPool(1, address(underlying), config);
    }

    function testInitPoolInvalidMaintenanceRate() public {
        facet.setMaxMaintenanceRate(100); // 1%
        Types.PoolConfig memory config = validConfig;
        config.maintenanceRateBps = 101;
        vm.expectRevert(); // InvalidMaintenanceRate
        facet.initPool(1, address(underlying), config);
    }

    function testInitPoolFixedTermConfigs() public {
        Types.PoolConfig memory config = validConfig;
        Types.FixedTermConfig[] memory terms = new Types.FixedTermConfig[](1);
        terms[0] = Types.FixedTermConfig({
            durationSecs: 30 days,
            apyBps: 500
        });
        // This is tricky because struct copying with dynamic arrays in memory is strict
        // We can't easily assign dynamic array to struct in memory if it wasn't initialized with it.
        // We have to recreate the struct.
        
        Types.PoolConfig memory newConfig = Types.PoolConfig({
            rollingApyBps: config.rollingApyBps,
            depositorLTVBps: config.depositorLTVBps,
            maintenanceRateBps: config.maintenanceRateBps,
            flashLoanFeeBps: config.flashLoanFeeBps,
            flashLoanAntiSplit: config.flashLoanAntiSplit,
            minDepositAmount: config.minDepositAmount,
            minLoanAmount: config.minLoanAmount,
            minTopupAmount: config.minTopupAmount,
            isCapped: config.isCapped,
            depositCap: config.depositCap,
            maxUserCount: config.maxUserCount,
            aumFeeMinBps: config.aumFeeMinBps,
            aumFeeMaxBps: config.aumFeeMaxBps,
            fixedTermConfigs: terms,
            borrowFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            repayFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            withdrawFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            flashFee: Types.ActionFeeConfig({amount: 0, enabled: false}),
            closeRollingFee: Types.ActionFeeConfig({amount: 0, enabled: false})
        });

        facet.initPool(1, address(underlying), newConfig);
        Types.PoolConfig memory storedConfig = facet.getPoolConfig(1);
        assertEq(storedConfig.fixedTermConfigs.length, 1);
        assertEq(storedConfig.fixedTermConfigs[0].durationSecs, 30 days);
    }
}

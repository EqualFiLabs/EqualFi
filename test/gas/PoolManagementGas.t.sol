// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract PoolManagementGasHarness is PoolManagementFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setActionFeeBounds(uint128 minAmount, uint128 maxAmount) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.actionFeeMin = minAmount;
        store.actionFeeMax = maxAmount;
        store.actionFeeBoundsSet = true;
    }

    function setMaxMaintenanceRate(uint16 rate) external {
        LibAppStorage.s().maxMaintenanceRateBps = rate;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }
}

contract PoolManagementGasTest is Test {
    PoolManagementGasHarness internal facet;
    MockERC20 internal token;
    PositionNFT internal nft;

    address internal treasury = address(0xBEEF);
    address internal manager = address(0xA11CE);

    function setUp() public {
        facet = new PoolManagementGasHarness();
        token = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();

        facet.setOwner(address(this));
        facet.setTreasury(treasury);
        facet.setPoolCreationFee(0);
        facet.setManagedPoolCreationFee(0.1 ether);
        facet.setActionFeeBounds(0, type(uint128).max);
        facet.setMaxMaintenanceRate(1000);
        facet.setPositionNFT(address(nft));

        nft.setMinter(address(this));
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory config) {
        config.rollingApyBps = 500;
        config.depositorLTVBps = 8000;
        config.maintenanceRateBps = 50;
        config.flashLoanFeeBps = 10;
        config.flashLoanAntiSplit = false;
        config.minDepositAmount = 1 ether;
        config.minLoanAmount = 1 ether;
        config.minTopupAmount = 0.1 ether;
        config.isCapped = false;
        config.depositCap = 0;
        config.maxUserCount = 10;
        config.aumFeeMinBps = 100;
        config.aumFeeMaxBps = 500;
        config.fixedTermConfigs = new Types.FixedTermConfig[](0);
        config.borrowFee = Types.ActionFeeConfig(0, false);
        config.repayFee = Types.ActionFeeConfig(0, false);
        config.withdrawFee = Types.ActionFeeConfig(0, false);
        config.flashFee = Types.ActionFeeConfig(0, false);
        config.closeRollingFee = Types.ActionFeeConfig(0, false);
    }

    function _managedConfig() internal view returns (Types.ManagedPoolConfig memory cfg) {
        Types.ActionFeeSet memory fees;
        fees.borrowFee = Types.ActionFeeConfig({amount: 1 ether, enabled: true});
        cfg = Types.ManagedPoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 50,
            flashLoanFeeBps: 10,
            flashLoanAntiSplit: false,
            minDepositAmount: 1 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.1 ether,
            isCapped: true,
            depositCap: 100 ether,
            maxUserCount: 10,
            aumFeeMinBps: 100,
            aumFeeMaxBps: 500,
            fixedTermConfigs: new Types.FixedTermConfig[](0),
            actionFees: fees,
            manager: manager,
            whitelistEnabled: true
        });
    }

    function test_gas_InitPoolWithActionFees() public {
        vm.pauseGasMetering();
        Types.PoolConfig memory config = _poolConfig();
        Types.ActionFeeSet memory fees;

        vm.resumeGasMetering();
        facet.initPoolWithActionFees(1, address(token), config, fees);
    }

    function test_gas_InitManagedPool() public {
        vm.pauseGasMetering();
        Types.ManagedPoolConfig memory cfg = _managedConfig();
        vm.deal(manager, 1 ether);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.initManagedPool{value: 0.1 ether}(1, address(token), cfg);
    }

    function _initManagedPool(uint256 pid) internal {
        Types.ManagedPoolConfig memory cfg = _managedConfig();
        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.1 ether}(pid, address(token), cfg);
    }

    function test_gas_SetRollingApy() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setRollingApy(1, 600);
    }

    function test_gas_SetDepositorLTV() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setDepositorLTV(1, 7500);
    }

    function test_gas_SetMinDepositAmount() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setMinDepositAmount(1, 2 ether);
    }

    function test_gas_SetMinLoanAmount() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setMinLoanAmount(1, 2 ether);
    }

    function test_gas_SetMinTopupAmount() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setMinTopupAmount(1, 0.2 ether);
    }

    function test_gas_SetDepositCap() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setDepositCap(1, 200 ether);
    }

    function test_gas_SetIsCapped() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setIsCapped(1, true);
    }

    function test_gas_SetMaxUserCount() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setMaxUserCount(1, 50);
    }

    function test_gas_SetMaintenanceRate() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setMaintenanceRate(1, 100);
    }

    function test_gas_SetFlashLoanFee() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setFlashLoanFee(1, 20);
    }

    function test_gas_SetActionFees() public {
        vm.pauseGasMetering();
        _initManagedPool(1);
        Types.ActionFeeSet memory fees;
        fees.borrowFee = Types.ActionFeeConfig({amount: 1 ether, enabled: true});

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setActionFees(1, fees);
    }

    function test_gas_AddToWhitelist() public {
        vm.pauseGasMetering();
        _initManagedPool(1);
        uint256 tokenId = nft.mint(manager, 1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.addToWhitelist(1, tokenId);
    }

    function test_gas_RemoveFromWhitelist() public {
        vm.pauseGasMetering();
        _initManagedPool(1);
        uint256 tokenId = nft.mint(manager, 1);
        vm.prank(manager);
        facet.addToWhitelist(1, tokenId);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.removeFromWhitelist(1, tokenId);
    }

    function test_gas_SetWhitelistEnabled() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.setWhitelistEnabled(1, false);
    }

    function test_gas_TransferManager() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.transferManager(1, address(0xB0B));
    }

    function test_gas_RenounceManager() public {
        vm.pauseGasMetering();
        _initManagedPool(1);

        vm.prank(manager);
        vm.resumeGasMetering();
        facet.renounceManager(1);
    }
}

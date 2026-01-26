// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeSystemsFlashLoanReceiver is IFlashLoanReceiver {
    uint16 internal feeBps;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata)
        external
        override
        returns (bytes32)
    {
        uint256 fee = (amount * feeBps) / 10_000;
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}

contract FeeSystemsFlashLoanHarness is FlashLoanFacet {
    function initPool(uint256 pid, address token, uint16 feeBps, bool antiSplit) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = token;
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = antiSplit;
        p.totalDeposits = 1_000_000 ether;
        p.trackedBalance = MockERC20(token).balanceOf(address(this));
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setTreasuryShare(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }
}

contract FeeSystemsMaintenanceHarness is MaintenanceFacet {
    function configurePool(
        uint256 pid,
        address underlying,
        uint256 poolDeposits,
        uint16 rateBps,
        uint64 lastTimestamp
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = poolDeposits;
        p.trackedBalance = poolDeposits;
        p.poolConfig.maintenanceRateBps = rateBps;
        p.lastMaintenanceTimestamp = lastTimestamp;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }
}

contract FeeSystemsPreservedPropertyTest is Test {
    address internal constant TREASURY = address(0xA11CE);
    address internal constant FOUNDATION = address(0xBEEF);

    function testProperty_FeeSystemsPreserved(
        uint256 flashAmount,
        uint16 flashFeeBps,
        uint16 treasuryShareBps,
        uint256 maintenanceDeposits,
        uint16 maintenanceRateBps,
        uint16 daysElapsed
    ) public {
        flashAmount = bound(flashAmount, 1 ether, 1_000 ether);
        flashFeeBps = uint16(bound(flashFeeBps, 1, 1_000));
        treasuryShareBps = uint16(bound(treasuryShareBps, 0, 10_000));
        maintenanceDeposits = bound(maintenanceDeposits, 10 ether, 1_000_000 ether);
        maintenanceRateBps = uint16(bound(maintenanceRateBps, 1, 1_000));
        daysElapsed = uint16(bound(daysElapsed, 1, 180));

        // Flash loan fee routing
        FeeSystemsFlashLoanHarness flashFacet = new FeeSystemsFlashLoanHarness();
        FeeSystemsFlashLoanReceiver receiver = new FeeSystemsFlashLoanReceiver();
        MockERC20 flashToken = new MockERC20("Flash Token", "FLASH", 18, 0);
        flashToken.mint(address(flashFacet), 2_000_000 ether);

        uint256 flashFee = (flashAmount * flashFeeBps) / 10_000;
        flashToken.mint(address(receiver), flashFee);
        receiver.setFeeBps(flashFeeBps);
        vm.prank(address(receiver));
        flashToken.approve(address(flashFacet), type(uint256).max);

        flashFacet.initPool(1, address(flashToken), flashFeeBps, false);
        flashFacet.setTreasury(TREASURY);
        flashFacet.setTreasuryShare(treasuryShareBps);

        uint256 treasuryBefore = flashToken.balanceOf(TREASURY);
        uint256 trackedBefore = flashFacet.trackedBalance(1);
        uint256 indexBefore = flashFacet.feeIndex(1);
        uint256 totalDeposits = flashFacet.totalDeposits(1);

        flashFacet.flashLoan(1, address(receiver), flashAmount, "");

        uint256 expectedTreasury = (flashFee * treasuryShareBps) / 10_000;
        uint256 expectedIndexAccrual = flashFee - expectedTreasury;
        uint256 expectedIndexDelta = (expectedIndexAccrual * 1e18) / totalDeposits;

        assertEq(flashToken.balanceOf(TREASURY) - treasuryBefore, expectedTreasury, "treasury share paid");
        assertEq(flashFacet.trackedBalance(1) - trackedBefore, expectedIndexAccrual, "tracked balance accrual");
        assertEq(flashFacet.feeIndex(1) - indexBefore, expectedIndexDelta, "fee index accrual");

        // Maintenance fee routing
        FeeSystemsMaintenanceHarness maintenanceFacet = new FeeSystemsMaintenanceHarness();
        MockERC20 maintenanceToken = new MockERC20("Maintenance Token", "MAINT", 18, 0);
        maintenanceFacet.setFoundationReceiver(FOUNDATION);

        vm.warp(200 days);
        uint64 lastTimestamp = uint64(block.timestamp - uint256(daysElapsed) * 1 days);
        maintenanceToken.mint(address(maintenanceFacet), maintenanceDeposits);
        maintenanceFacet.configurePool(1, address(maintenanceToken), maintenanceDeposits, maintenanceRateBps, lastTimestamp);

        uint256 expectedMaintenance = (maintenanceDeposits * maintenanceRateBps * daysElapsed) / (365 * 10_000);
        uint256 maintenanceTrackedBefore = maintenanceFacet.trackedBalance(1);
        uint256 maintenanceTotalBefore = maintenanceFacet.totalDeposits(1);
        uint256 foundationBefore = maintenanceToken.balanceOf(FOUNDATION);

        maintenanceFacet.pokeMaintenance(1);

        assertEq(maintenanceToken.balanceOf(FOUNDATION) - foundationBefore, expectedMaintenance, "foundation paid");
        assertEq(
            maintenanceFacet.totalDeposits(1),
            maintenanceTotalBefore - expectedMaintenance,
            "total deposits reduced"
        );
        assertEq(
            maintenanceFacet.trackedBalance(1),
            maintenanceTrackedBefore - expectedMaintenance,
            "tracked balance reduced"
        );
    }
}

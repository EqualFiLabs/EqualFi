// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract TrackedBalancePositionHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initNativePool(uint256 pid, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = address(0);
        p.initialized = true;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.poolConfig.minTopupAmount = 1;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }
}

contract TrackedBalanceLendingHarness is LendingFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initNativePool(uint256 pid, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = address(0);
        p.initialized = true;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.poolConfig.minTopupAmount = 1;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedPosition(uint256 pid, bytes32 key, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[key] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[key] = p.feeIndex;
        p.userMaintenanceIndex[key] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(key, pid, true);
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }
}

contract TrackedBalanceFlashReceiver is IFlashLoanReceiver {
    uint16 internal feeBps;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        if (token == address(0)) {
            uint256 fee = (amount * feeBps) / 10_000;
            (bool success,) = msg.sender.call{value: amount + fee}("");
            require(success, "repay failed");
        }
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    receive() external payable {}
}

contract TrackedBalanceFlashHarness is FlashLoanFacet {
    function initNativePool(uint256 pid, uint16 feeBps, uint256 trackedBalance, uint256 deposits) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = address(0);
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.trackedBalance = trackedBalance;
        p.totalDeposits = deposits;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    receive() external payable {}
}

contract TrackedBalanceNativeEthPropertyTest is Test {
    uint256 internal constant PID = 1;
    address internal user = address(0xA11CE);

    /// Feature: native-eth-support, Property 2: TrackedBalance Invariant
    function testFuzz_trackedBalanceDepositWithdraw(uint96 depositAmount, uint96 withdrawAmount) public {
        depositAmount = uint96(bound(uint256(depositAmount), 1, 100 ether));
        withdrawAmount = uint96(bound(uint256(withdrawAmount), 1, depositAmount));

        TrackedBalancePositionHarness facet = new TrackedBalancePositionHarness();
        PositionNFT nft = new PositionNFT();
        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initNativePool(PID, 10_000);

        uint256 extra = 1 ether;
        vm.deal(address(facet), uint256(depositAmount) + extra);
        facet.setNativeTrackedTotal(0);

        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(PID, depositAmount);

        assertEq(facet.trackedBalance(PID), depositAmount, "tracked after deposit");
        assertEq(facet.totalDeposits(PID), depositAmount, "deposits after deposit");
        assertEq(facet.nativeTrackedTotal(), depositAmount, "native tracked after deposit");
        assertLe(facet.nativeTrackedTotal(), address(facet).balance, "native tracked <= balance");

        uint256 userBalanceBefore = user.balance;
        vm.prank(user);
        facet.withdrawFromPosition(tokenId, PID, withdrawAmount);

        assertEq(facet.trackedBalance(PID), depositAmount - withdrawAmount, "tracked after withdraw");
        assertEq(facet.totalDeposits(PID), depositAmount - withdrawAmount, "deposits after withdraw");
        assertEq(facet.nativeTrackedTotal(), depositAmount - withdrawAmount, "native tracked after withdraw");
        assertEq(user.balance - userBalanceBefore, withdrawAmount, "user received withdraw");
        assertLe(facet.nativeTrackedTotal(), address(facet).balance, "native tracked <= balance");
    }

    /// Feature: native-eth-support, Property 2: TrackedBalance Invariant
    function testFuzz_trackedBalanceBorrowRepay(uint96 depositAmount, uint96 borrowAmount) public {
        depositAmount = uint96(bound(uint256(depositAmount), 1 ether, 200 ether));
        borrowAmount = uint96(bound(uint256(borrowAmount), 1, depositAmount));

        TrackedBalanceLendingHarness facet = new TrackedBalanceLendingHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.configurePositionNFT(address(nft));
        facet.initNativePool(PID, 10_000);

        uint256 extra = uint256(borrowAmount) + 1 ether;
        vm.deal(address(facet), uint256(depositAmount) + extra);
        facet.setNativeTrackedTotal(depositAmount);

        uint256 tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, depositAmount);

        uint256 userBalanceBefore = user.balance;
        vm.prank(user);
        facet.openRollingFromPosition(tokenId, PID, borrowAmount);

        assertEq(facet.trackedBalance(PID), depositAmount - borrowAmount, "tracked after borrow");
        assertEq(facet.nativeTrackedTotal(), depositAmount - borrowAmount, "native tracked after borrow");
        assertEq(user.balance - userBalanceBefore, borrowAmount, "user received borrow");
        assertLe(facet.nativeTrackedTotal(), address(facet).balance, "native tracked <= balance");

        vm.prank(user);
        facet.makePaymentFromPosition(tokenId, PID, borrowAmount);

        assertEq(facet.trackedBalance(PID), depositAmount, "tracked after repay");
        assertEq(facet.nativeTrackedTotal(), depositAmount, "native tracked after repay");
        assertLe(facet.nativeTrackedTotal(), address(facet).balance, "native tracked <= balance");
    }

    /// Feature: native-eth-support, Property 2: TrackedBalance Invariant
    function testFuzz_trackedBalanceFlashLoan(uint96 amount, uint16 feeBps) public {
        amount = uint96(bound(uint256(amount), 1 ether, 50 ether));
        feeBps = uint16(bound(uint256(feeBps), 1, 500));
        uint256 fee = (uint256(amount) * feeBps) / 10_000;

        TrackedBalanceFlashHarness facet = new TrackedBalanceFlashHarness();
        TrackedBalanceFlashReceiver receiver = new TrackedBalanceFlashReceiver();
        receiver.setFeeBps(feeBps);

        facet.initNativePool(PID, feeBps, amount, amount);
        facet.setNativeTrackedTotal(amount);
        vm.deal(address(facet), amount);
        vm.deal(address(receiver), fee);

        uint256 trackedBefore = facet.trackedBalance(PID);
        uint256 nativeTrackedBefore = facet.nativeTrackedTotal();

        facet.flashLoan(PID, address(receiver), amount, "");

        assertEq(facet.trackedBalance(PID), trackedBefore + fee, "tracked after flash");
        assertEq(facet.nativeTrackedTotal(), nativeTrackedBefore + fee, "native tracked after flash");
        assertLe(facet.nativeTrackedTotal(), address(facet).balance, "native tracked <= balance");
    }
}

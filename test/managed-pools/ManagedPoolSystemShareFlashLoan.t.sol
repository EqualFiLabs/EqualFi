// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedFlashLoanReceiver is IFlashLoanReceiver {
    function onFlashLoan(address, address, uint256, bytes calldata) external pure override returns (bytes32) {
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }

    function approveToken(address token, address spender, uint256 amount) external {
        MockERC20(token).approve(spender, amount);
    }
}

contract ManagedFlashLoanHarness is FlashLoanFacet {
    function initPool(uint256 pid, address token, uint16 feeBps, bool isManaged) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = token;
        p.initialized = true;
        p.isManagedPool = isManaged;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = false;
    }

    function setPoolBalances(uint256 pid, uint256 totalDeposits, uint256 tracked) external {
        Types.PoolData storage p = s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.trackedBalance = tracked;
    }

    function setAssetToPoolId(address token, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[token] = pid;
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }
}

contract ManagedPoolSystemShareFlashLoanTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;
    uint16 private constant FLASH_FEE_BPS = 100; // 1%

    ManagedFlashLoanHarness private facet;
    ManagedFlashLoanReceiver private receiver;
    MockERC20 private token;

    function setUp() public {
        facet = new ManagedFlashLoanHarness();
        receiver = new ManagedFlashLoanReceiver();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        token.mint(address(facet), 1_000_000 ether);
        token.mint(address(receiver), 1_000_000 ether);
        receiver.approveToken(address(token), address(facet), type(uint256).max);

        facet.setTreasury(address(0));
        facet.setFoundationReceiver(address(0));
        facet.setManagedPoolSystemShareBps(2000); // 20%

        facet.initPool(BASE_PID, address(token), 0, false);
        facet.initPool(MANAGED_PID, address(token), FLASH_FEE_BPS, true);
        facet.setAssetToPoolId(address(token), BASE_PID);

        facet.setPoolBalances(BASE_PID, 100 ether, 1_000_000 ether);
        facet.setPoolBalances(MANAGED_PID, 100 ether, 1_000_000 ether);
    }

    function testFlashLoanRoutesSystemShareToBasePoolFeeIndex() public {
        uint256 amount = 100 ether;
        uint256 fee = (amount * FLASH_FEE_BPS) / 10_000; // 1 ether
        uint256 systemShare = (fee * 2000) / 10_000; // 0.2 ether
        uint256 managedShare = fee - systemShare; // 0.8 ether

        uint256 baseBefore = facet.feeIndex(BASE_PID);
        uint256 managedBefore = facet.feeIndex(MANAGED_PID);

        facet.flashLoan(MANAGED_PID, address(receiver), amount, "");

        uint256 baseAfter = facet.feeIndex(BASE_PID);
        uint256 managedAfter = facet.feeIndex(MANAGED_PID);

        uint256 expectedBaseDelta = (systemShare * 1e18) / 100 ether;
        uint256 expectedManagedDelta = (managedShare * 1e18) / 100 ether;

        assertEq(baseAfter - baseBefore, expectedBaseDelta, "base fee index delta mismatch");
        assertEq(managedAfter - managedBefore, expectedManagedDelta, "managed fee index delta mismatch");
    }
}

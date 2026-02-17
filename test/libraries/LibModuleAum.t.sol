// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleAum} from "../../src/libraries/LibModuleAum.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LibModuleAumHarness {
    receive() external payable {}

    function setupErc20Pool(uint256 pid, address token, uint256 trackedBalance, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = token;
        p.trackedBalance = trackedBalance;
        p.totalDeposits = totalDeposits;
    }

    function setupNativePool(uint256 pid, uint256 trackedBalance, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = address(0);
        p.trackedBalance = trackedBalance;
        p.totalDeposits = totalDeposits;
    }

    function setPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setFeeSplits(uint16 treasuryBps, uint16 activeCreditBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = treasuryBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = activeCreditBps;
        store.activeCreditShareConfigured = true;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function setModuleConfig(
        uint256 moduleId,
        address owner,
        uint16 moduleAumBps,
        uint16 defaultAumBps,
        uint16 deactivationGraceEpochs,
        bool inactive
    ) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        ms.defaultModuleAumBps = defaultAumBps;
        ms.deactivationGraceEpochs = deactivationGraceEpochs;
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = owner;
        m.aumBps = moduleAumBps;
        m.inactive = inactive;
    }

    function setModuleEncumbered(bytes32 positionKey, uint256 pid, uint256 moduleId, uint256 amount) external {
        if (amount == 0) return;
        LibModuleEncumbrance.encumber(positionKey, pid, moduleId, amount);
    }

    function accrue(bytes32 positionKey, uint256 pid, uint256 moduleId)
        external
        returns (
            uint256 epochs,
            uint256 feeDue,
            uint256 charged,
            uint256 shortfall,
            bool delinquent,
            bool deactivated,
            uint64 lastAumEpoch
        )
    {
        LibModuleAum.AccrualResult memory r = LibModuleAum.accrue(positionKey, pid, moduleId);
        return (r.epochs, r.feeDue, r.charged, r.shortfall, r.delinquent, r.deactivated, r.lastAumEpoch);
    }

    function pendingEpochs(bytes32 positionKey, uint256 pid, uint256 moduleId) external view returns (uint256) {
        return LibModuleAum.pendingEpochs(positionKey, pid, moduleId);
    }

    function delinquentEpochs(bytes32 positionKey, uint256 pid, uint256 moduleId) external view returns (uint256) {
        return LibModuleAum.delinquentEpochs(positionKey, pid, moduleId);
    }

    function getTupleState(bytes32 positionKey, uint256 pid, uint256 moduleId)
        external
        view
        returns (uint64 lastAumEpoch, bool delinquent, uint64 delinquentSince, uint256 lastShortfall)
    {
        LibModuleRegistry.TupleAumState storage st = LibModuleRegistry.tupleAumState(positionKey, pid, moduleId);
        return (st.lastAumEpoch, st.delinquent, st.delinquentSince, st.lastShortfall);
    }

    function getPoolState(bytes32 positionKey, uint256 pid)
        external
        view
        returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 nativeTrackedTotal)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.userPrincipal[positionKey], p.totalDeposits, p.trackedBalance, LibAppStorage.s().nativeTrackedTotal);
    }

    function moduleInactive(uint256 moduleId) external view returns (bool) {
        return LibModuleRegistry.module(moduleId).inactive;
    }
}

contract LibModuleAumTest is Test {
    LibModuleAumHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    bytes32 internal constant POSITION_KEY_TWO = keccak256("POSITION_TWO");
    uint256 internal constant POOL_ID = 5;
    uint256 internal constant MODULE_ID = 9;
    uint256 internal constant YEAR_DENOM = 365 * 10_000;

    address internal treasury = address(0xBEEF);

    function setUp() public {
        h = new LibModuleAumHarness();
    }

    function _seedErc20Env(uint256 principal, uint256 trackedBalance, uint256 totalDeposits) internal returns (MockERC20) {
        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        h.setupErc20Pool(POOL_ID, address(token), trackedBalance, totalDeposits);
        h.setPrincipal(POOL_ID, POSITION_KEY, principal);
        h.setTreasury(treasury);
        h.setFeeSplits(10_000, 0);
        token.mint(address(h), trackedBalance);
        return token;
    }

    function test_firstTouch_initializesCheckpointWithoutRetroCharge() public {
        MockERC20 token = _seedErc20Env(1_000, 1_000, 1_000);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, 3_650_000);

        vm.warp(100 days + 5 hours);
        (uint256 epochs, uint256 feeDue, uint256 charged, uint256 shortfall,, bool deactivated, uint64 lastAumEpoch) =
            h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);
        assertEq(epochs, 0);
        assertEq(feeDue, 0);
        assertEq(charged, 0);
        assertEq(shortfall, 0);
        assertFalse(deactivated);
        assertEq(lastAumEpoch, uint64((block.timestamp / 1 days) * 1 days));

        (uint256 principal, uint256 totalDeposits, uint256 trackedBalance,) = h.getPoolState(POSITION_KEY, POOL_ID);
        assertEq(principal, 1_000);
        assertEq(totalDeposits, 1_000);
        assertEq(trackedBalance, 1_000);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_pendingEpochs_helperCountsOnlyFullDays() public {
        _seedErc20Env(100, 100, 100);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, 1000);

        vm.warp(1 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);

        vm.warp(1 days + 23 hours);
        assertEq(h.pendingEpochs(POSITION_KEY, POOL_ID, MODULE_ID), 0);

        vm.warp(2 days);
        assertEq(h.pendingEpochs(POSITION_KEY, POOL_ID, MODULE_ID), 1);
    }

    function test_feeFormulaAndPrincipalDebit_routeTreasuryAndTrackedBalance() public {
        MockERC20 token = _seedErc20Env(1_000, 1_000, 1_000);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, 3_650_000);

        vm.warp(1 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // first touch

        vm.warp(2 days);
        (uint256 epochs, uint256 feeDue, uint256 charged, uint256 shortfall, bool delinquent,,) =
            h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);

        assertEq(epochs, 1);
        assertEq(feeDue, 100);
        assertEq(charged, 100);
        assertEq(shortfall, 0);
        assertFalse(delinquent);

        (uint256 principal, uint256 totalDeposits, uint256 trackedBalance,) = h.getPoolState(POSITION_KEY, POOL_ID);
        assertEq(principal, 900);
        assertEq(totalDeposits, 900);
        assertEq(trackedBalance, 900);
        assertEq(token.balanceOf(treasury), 100);
    }

    function test_nativeTreasuryRouting_debitsNativeTrackedTotalExactlyOnce() public {
        h.setupNativePool(POOL_ID, 1_000, 1_000);
        h.setPrincipal(POOL_ID, POSITION_KEY, 1_000);
        h.setNativeTrackedTotal(1_000);
        h.setTreasury(treasury);
        h.setFeeSplits(10_000, 0);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, 3_650_000);

        vm.deal(address(h), 1_000);
        vm.warp(1 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // first touch

        vm.warp(2 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);

        (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 nativeTrackedTotal) =
            h.getPoolState(POSITION_KEY, POOL_ID);
        assertEq(principal, 900);
        assertEq(totalDeposits, 900);
        assertEq(trackedBalance, 900);
        assertEq(nativeTrackedTotal, 900);
        assertEq(treasury.balance, 100);
    }

    function test_delinquencyAndGraceWindow_permanentlyDeactivatesModule() public {
        MockERC20 token = _seedErc20Env(10, 1_000, 10);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);

        uint256 encumbered = 30 * YEAR_DENOM / 100;
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, encumbered);

        vm.warp(1 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // first touch

        vm.warp(2 days);
        (uint256 epochs1, uint256 feeDue1, uint256 charged1, uint256 shortfall1, bool delinquent1, bool deactivated1,) =
            h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);
        assertEq(epochs1, 1);
        assertEq(feeDue1, 30);
        assertEq(charged1, 10);
        assertEq(shortfall1, 20);
        assertTrue(delinquent1);
        assertFalse(deactivated1);
        assertFalse(h.moduleInactive(MODULE_ID));

        vm.warp(3 days);
        (,,,, bool delinquent2, bool deactivated2,) = h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);
        assertTrue(delinquent2);
        assertFalse(deactivated2);
        assertEq(h.delinquentEpochs(POSITION_KEY, POOL_ID, MODULE_ID), 1);
        assertFalse(h.moduleInactive(MODULE_ID));

        vm.warp(4 days);
        (uint256 epochs3, uint256 feeDue3, uint256 charged3, uint256 shortfall3, bool delinquent3, bool deactivated3,) =
            h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);
        assertEq(epochs3, 1);
        assertEq(feeDue3, 30);
        assertEq(charged3, 0);
        assertEq(shortfall3, 30);
        assertTrue(delinquent3);
        assertTrue(deactivated3);
        assertTrue(h.moduleInactive(MODULE_ID));

        (, bool tupleDelinquent,, uint256 lastShortfall) = h.getTupleState(POSITION_KEY, POOL_ID, MODULE_ID);
        assertTrue(tupleDelinquent);
        assertEq(lastShortfall, 30);
        assertEq(token.balanceOf(treasury), 10);
    }

    function test_globalDeactivationFromOneTuple_doesNotBlockOtherTupleAccrual() public {
        _seedErc20Env(10, 2_000, 2_000);
        h.setPrincipal(POOL_ID, POSITION_KEY_TWO, 1_000);
        h.setModuleConfig(MODULE_ID, address(0xABCD), 100, 0, 2, false);

        uint256 delinquentEncumbered = 30 * YEAR_DENOM / 100; // 30/day at 1% AUM
        uint256 healthyEncumbered = 365_000; // 10/day at 1% AUM
        h.setModuleEncumbered(POSITION_KEY, POOL_ID, MODULE_ID, delinquentEncumbered);
        h.setModuleEncumbered(POSITION_KEY_TWO, POOL_ID, MODULE_ID, healthyEncumbered);

        vm.warp(1 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID);
        h.accrue(POSITION_KEY_TWO, POOL_ID, MODULE_ID);

        vm.warp(2 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // delinquent start
        vm.warp(3 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // grace epoch 1
        vm.warp(4 days);
        h.accrue(POSITION_KEY, POOL_ID, MODULE_ID); // grace epoch 2 => deactivated
        assertTrue(h.moduleInactive(MODULE_ID), "module should deactivate globally");

        vm.warp(5 days);
        (uint256 epochs, uint256 feeDue, uint256 charged, uint256 shortfall,, bool deactivated,) =
            h.accrue(POSITION_KEY_TWO, POOL_ID, MODULE_ID);
        assertEq(epochs, 4, "healthy tuple should accrue elapsed epochs despite global deactivation");
        assertEq(feeDue, 40, "fee due should be deterministic for healthy tuple");
        assertEq(charged, 40, "healthy tuple should still be chargeable");
        assertEq(shortfall, 0, "healthy tuple should remain solvent");
        assertFalse(deactivated, "deactivation should not be re-triggered by healthy tuple");

        (uint256 principal,,,) = h.getPoolState(POSITION_KEY_TWO, POOL_ID);
        assertEq(principal, 960, "healthy tuple principal should continue to decay by AUM after deactivation");
    }
}

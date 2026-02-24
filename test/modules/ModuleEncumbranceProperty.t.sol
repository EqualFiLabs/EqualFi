// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {LibModuleAum} from "../../src/libraries/LibModuleAum.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {Types} from "../../src/libraries/Types.sol";
import {ModuleInactive} from "../../src/libraries/Errors.sol";

contract ModuleEncumbrancePropertyHarness is ModuleGatewayFacet {
    receive() external payable {}

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function setupErc20Pool(uint256 pid, address token, uint256 trackedAmount, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = token;
        p.trackedBalance = trackedAmount;
        p.totalDeposits = totalDeposits;
    }

    function setupNativePool(uint256 pid, uint256 trackedAmount, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = address(0);
        p.trackedBalance = trackedAmount;
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
        bool paused,
        bool inactive,
        uint16 aumBps,
        uint16 defaultAumBps,
        uint16 graceEpochs
    ) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        ms.defaultModuleAumBps = defaultAumBps;
        ms.deactivationGraceEpochs = graceEpochs;
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = owner;
        m.paused = paused;
        m.inactive = inactive;
        m.aumBps = aumBps;
    }

    function setModuleAciPaused(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
    }

    function joinPool(bytes32 positionKey, uint256 poolId) external {
        LibPoolMembership._joinPool(positionKey, poolId);
    }

    function setModuleEncumberedRaw(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        if (amount == 0) return;
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function setIndexEncumberedRaw(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        if (amount == 0) return;
        LibEncumbrance.encumberIndex(positionKey, poolId, indexId, amount);
    }

    function accrueAum(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        returns (uint256 epochs, uint256 feeDue, uint256 charged, uint256 shortfall, uint64 lastEpoch)
    {
        LibModuleAum.AccrualResult memory r = LibModuleAum.accrue(positionKey, poolId, moduleId);
        return (r.epochs, r.feeDue, r.charged, r.shortfall, r.lastAumEpoch);
    }

    function availablePrincipal(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[poolId];
        return LibSolvencyChecks.calculateAvailablePrincipal(p, positionKey, poolId);
    }

    function principalOf(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function trackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function activeCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function moduleEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function indexEncumberedForIndex(bytes32 positionKey, uint256 poolId, uint256 indexId) external view returns (uint256) {
        return LibEncumbrance.getIndexEncumberedForIndex(positionKey, poolId, indexId);
    }

    function lastAumEpoch(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint64) {
        return LibModuleRegistry.tupleAumState(positionKey, poolId, moduleId).lastAumEpoch;
    }

    function moduleInactive(uint256 moduleId) external view returns (bool) {
        return LibModuleRegistry.module(moduleId).inactive;
    }
}

contract ModuleEncumbrancePropertyTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant MODULE_OWNER = address(0xCAFE);
    address internal constant TREASURY = address(0xBEEF);

    uint256 internal constant POOL_ID = 1;
    uint256 internal constant MODULE_ID = 1;
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant INDEX_ID = 77;
    uint16 internal constant AUM_BPS = 100;

    function _bootstrapErc20(uint256 principal, uint256 trackedBalance)
        internal
        returns (ModuleEncumbrancePropertyHarness h, PositionNFT nft, MockERC20 token, bytes32 positionKey)
    {
        h = new ModuleEncumbrancePropertyHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        h.setPositionNFT(address(nft));
        nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(TOKEN_ID);

        token = new MockERC20("Mock", "MOCK", 18, 0);
        h.setupErc20Pool(POOL_ID, address(token), trackedBalance, trackedBalance);
        h.setPrincipal(POOL_ID, positionKey, principal);
        h.setTreasury(TREASURY);
        h.setFeeSplits(10_000, 0);
        h.setModuleConfig(MODULE_ID, MODULE_OWNER, false, false, AUM_BPS, AUM_BPS, 2);
        h.joinPool(positionKey, POOL_ID);
        token.mint(address(h), trackedBalance);
    }

    function _bootstrapNative(uint256 principal, uint256 trackedBalance)
        internal
        returns (ModuleEncumbrancePropertyHarness h, PositionNFT nft, bytes32 positionKey)
    {
        h = new ModuleEncumbrancePropertyHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        h.setPositionNFT(address(nft));
        nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(TOKEN_ID);

        h.setupNativePool(POOL_ID, trackedBalance, trackedBalance);
        h.setPrincipal(POOL_ID, positionKey, principal);
        h.setNativeTrackedTotal(trackedBalance);
        h.setTreasury(TREASURY);
        h.setFeeSplits(10_000, 0);
        h.setModuleConfig(MODULE_ID, MODULE_OWNER, false, false, AUM_BPS, AUM_BPS, 2);
        h.joinPool(positionKey, POOL_ID);
        vm.deal(address(h), trackedBalance);
    }

    function testFuzz_reservationAvailabilityConservation(uint96 principalSeed, uint96 encSeed, uint96 unencSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1e6, 1e24);
        (ModuleEncumbrancePropertyHarness h, PositionNFT nft,, bytes32 positionKey) = _bootstrapErc20(principal, principal);

        uint256 enc = bound(uint256(encSeed), 0, principal);
        uint256 unenc = bound(uint256(unencSeed), 0, enc);

        vm.prank(OWNER);
        h.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, enc);
        vm.prank(OWNER);
        h.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, unenc);

        uint256 expectedEnc = enc - unenc;
        assertEq(h.moduleEncumberedForModule(positionKey, POOL_ID, MODULE_ID), expectedEnc);
        assertEq(h.availablePrincipal(POOL_ID, positionKey), principal - expectedEnc);
        nft; // silence warning for tuple return readability
    }

    function testFuzz_aumBaseIsolationToTupleEncumberedAmount(uint96 encSeed, uint32 epochsSeed) public {
        uint256 enc = bound(uint256(encSeed), 365_000, 1e22);
        uint256 epochs = bound(uint256(epochsSeed), 1, 30);

        uint256 principalLow = enc + 1e9;
        uint256 principalHigh = principalLow * 5 + 123;

        (ModuleEncumbrancePropertyHarness h1, PositionNFT n1,, bytes32 k1) = _bootstrapErc20(principalLow, principalLow);
        (ModuleEncumbrancePropertyHarness h2, PositionNFT n2,, bytes32 k2) = _bootstrapErc20(principalHigh, principalHigh);
        n1; n2;

        h1.setModuleEncumberedRaw(k1, POOL_ID, MODULE_ID, enc);
        h2.setModuleEncumberedRaw(k2, POOL_ID, MODULE_ID, enc);

        vm.warp(1 days);
        h1.accrueAum(k1, POOL_ID, MODULE_ID); // first touch
        h2.accrueAum(k2, POOL_ID, MODULE_ID); // first touch

        vm.warp(1 days + (epochs * 1 days));
        (, uint256 feeDue1,,,) = h1.accrueAum(k1, POOL_ID, MODULE_ID);
        (, uint256 feeDue2,,,) = h2.accrueAum(k2, POOL_ID, MODULE_ID);

        uint256 expected = (enc * AUM_BPS * epochs) / (365 * 10_000);
        assertEq(feeDue1, feeDue2);
        assertEq(feeDue1, expected);
    }

    function testFuzz_epochDeterminism(uint96 encSeed, uint8 epochsSeed) public {
        uint256 feeUnit = (365 * 10_000) / AUM_BPS; // exact per-epoch fee unit for AUM_BPS=100
        uint256 enc = bound(uint256(encSeed), feeUnit, 1e21);
        enc = enc - (enc % feeUnit);
        uint256 epochs = bound(uint256(epochsSeed), 1, 20);
        uint256 principal = enc * 100 + 1e12;

        (ModuleEncumbrancePropertyHarness hOnce, PositionNFT n1,, bytes32 k1) = _bootstrapErc20(principal, principal);
        (ModuleEncumbrancePropertyHarness hStep, PositionNFT n2,, bytes32 k2) = _bootstrapErc20(principal, principal);
        n1; n2;

        hOnce.setModuleEncumberedRaw(k1, POOL_ID, MODULE_ID, enc);
        hStep.setModuleEncumberedRaw(k2, POOL_ID, MODULE_ID, enc);

        vm.warp(1 days);
        hOnce.accrueAum(k1, POOL_ID, MODULE_ID); // first touch
        hStep.accrueAum(k2, POOL_ID, MODULE_ID); // first touch

        for (uint256 i = 1; i <= epochs; i++) {
            vm.warp(1 days + (i * 1 days));
            hStep.accrueAum(k2, POOL_ID, MODULE_ID);
        }

        vm.warp(1 days + (epochs * 1 days));
        hOnce.accrueAum(k1, POOL_ID, MODULE_ID);

        assertEq(hOnce.principalOf(POOL_ID, k1), hStep.principalOf(POOL_ID, k2));
        assertEq(hOnce.trackedBalance(POOL_ID), hStep.trackedBalance(POOL_ID));
        assertEq(hOnce.lastAumEpoch(k1, POOL_ID, MODULE_ID), hStep.lastAumEpoch(k2, POOL_ID, MODULE_ID));
    }

    function testFuzz_noRetroactiveFirstTouch(uint96 principalSeed, uint96 encSeed, uint16 daysSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1e6, 1e24);
        uint256 enc = bound(uint256(encSeed), 1, principal);
        uint256 elapsedDays = bound(uint256(daysSeed), 2, 365);

        (ModuleEncumbrancePropertyHarness h, PositionNFT n,, bytes32 key) = _bootstrapErc20(principal, principal);
        n;
        h.setModuleEncumberedRaw(key, POOL_ID, MODULE_ID, enc);

        uint256 principalBefore = h.principalOf(POOL_ID, key);
        vm.warp(elapsedDays * 1 days);
        (, uint256 feeDue, uint256 charged, uint256 shortfall,) = h.accrueAum(key, POOL_ID, MODULE_ID);
        assertEq(feeDue, 0);
        assertEq(charged, 0);
        assertEq(shortfall, 0);
        assertEq(h.principalOf(POOL_ID, key), principalBefore);
    }

    function testFuzz_aciPauseGatesIncreasesOnly(uint96 principalSeed, uint96 e1Seed, uint96 e2Seed) public {
        uint256 principal = bound(uint256(principalSeed), 1e9, 1e24);
        (ModuleEncumbrancePropertyHarness h, PositionNFT n,,) = _bootstrapErc20(principal, principal);
        n;

        uint256 enc1 = bound(uint256(e1Seed), 1, principal / 3);
        uint256 enc2 = bound(uint256(e2Seed), 1, enc1);

        vm.prank(OWNER);
        h.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, enc1);
        assertEq(h.activeCreditPrincipalTotal(POOL_ID), enc1);

        h.setModuleAciPaused(true);
        vm.prank(OWNER);
        h.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, enc2);
        assertEq(h.activeCreditPrincipalTotal(POOL_ID), enc1);

        vm.prank(OWNER);
        h.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, enc2);
        assertEq(h.activeCreditPrincipalTotal(POOL_ID), enc1 - enc2);
    }

    function testFuzz_namespaceIsolation(uint96 principalSeed, uint96 moduleSeed, uint96 indexSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1e9, 1e24);
        uint256 moduleAmt = bound(uint256(moduleSeed), 1, principal / 2);
        uint256 indexAmt = bound(uint256(indexSeed), 1, principal / 2);

        (ModuleEncumbrancePropertyHarness h, PositionNFT n,, bytes32 key) = _bootstrapErc20(principal, principal);
        n;

        h.setIndexEncumberedRaw(key, POOL_ID, INDEX_ID, indexAmt);
        uint256 indexBefore = h.indexEncumberedForIndex(key, POOL_ID, INDEX_ID);

        vm.prank(OWNER);
        h.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, moduleAmt);
        vm.prank(OWNER);
        h.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, moduleAmt / 2);

        assertEq(h.indexEncumberedForIndex(key, POOL_ID, INDEX_ID), indexBefore);
        uint256 moduleBefore = h.moduleEncumberedForModule(key, POOL_ID, MODULE_ID);

        h.setIndexEncumberedRaw(key, POOL_ID, INDEX_ID, 1);
        assertEq(h.moduleEncumberedForModule(key, POOL_ID, MODULE_ID), moduleBefore);
    }

    function testFuzz_nativeTrackedInvariant(uint96 principalSeed, uint96 encSeed, uint8 stepsSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1e9, 1e24);
        uint256 enc = bound(uint256(encSeed), 365_000, principal);
        uint256 steps = bound(uint256(stepsSeed), 1, 15);

        (ModuleEncumbrancePropertyHarness h, PositionNFT n, bytes32 key) = _bootstrapNative(principal, principal);
        n;
        h.setModuleEncumberedRaw(key, POOL_ID, MODULE_ID, enc);

        for (uint256 i; i <= steps; i++) {
            vm.warp((i + 1) * 1 days);
            h.accrueAum(key, POOL_ID, MODULE_ID);
            assertLe(h.nativeTrackedTotal(), address(h).balance);
        }
    }

    function testFuzz_principalChargedAumDebitsTrackedExactlyOnce(uint96 principalSeed, uint96 encSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1e9, 1e24);
        uint256 enc = bound(uint256(encSeed), 365_000, principal);

        (ModuleEncumbrancePropertyHarness h, PositionNFT n, MockERC20 token, bytes32 key) = _bootstrapErc20(principal, principal);
        n;
        h.setModuleEncumberedRaw(key, POOL_ID, MODULE_ID, enc);

        vm.warp(1 days);
        h.accrueAum(key, POOL_ID, MODULE_ID); // first touch

        uint256 trackedBefore = h.trackedBalance(POOL_ID);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        vm.warp(2 days);
        (, uint256 feeDue, uint256 charged,,) = h.accrueAum(key, POOL_ID, MODULE_ID);
        uint256 trackedAfter = h.trackedBalance(POOL_ID);
        uint256 treasuryAfter = token.balanceOf(TREASURY);

        assertEq(charged, feeDue);
        assertEq(trackedBefore - trackedAfter, charged);
        assertEq(treasuryAfter - treasuryBefore, charged);
    }

    function test_multiUserLiveness_afterGlobalDeactivation() public {
        address borrowerTwo = address(0xB0B);

        (ModuleEncumbrancePropertyHarness h, PositionNFT nft, MockERC20 token, bytes32 keyOne) = _bootstrapErc20(2_000_000, 2_000_000);
        uint256 tokenIdTwo = nft.mint(borrowerTwo, POOL_ID);
        bytes32 keyTwo = nft.getPositionKey(tokenIdTwo);

        h.setPrincipal(POOL_ID, keyOne, 10);
        h.setPrincipal(POOL_ID, keyTwo, 1_000);
        h.joinPool(keyTwo, POOL_ID);
        h.setModuleConfig(MODULE_ID, MODULE_OWNER, false, false, AUM_BPS, AUM_BPS, 2);

        uint256 riskyEncumbered = (30 * 365 * 10_000) / AUM_BPS; // 30/day at 1% AUM
        uint256 healthyEncumbered = 365_000; // 10/day at 1% AUM
        h.setModuleEncumberedRaw(keyOne, POOL_ID, MODULE_ID, riskyEncumbered);
        h.setModuleEncumberedRaw(keyTwo, POOL_ID, MODULE_ID, healthyEncumbered);

        vm.warp(1 days);
        h.accrueAum(keyOne, POOL_ID, MODULE_ID);
        h.accrueAum(keyTwo, POOL_ID, MODULE_ID);

        vm.warp(2 days);
        h.accrueAum(keyOne, POOL_ID, MODULE_ID);
        vm.warp(3 days);
        h.accrueAum(keyOne, POOL_ID, MODULE_ID);
        vm.warp(4 days);
        h.accrueAum(keyOne, POOL_ID, MODULE_ID);
        assertTrue(h.moduleInactive(MODULE_ID), "one delinquent tuple should globally deactivate module");

        vm.prank(borrowerTwo);
        vm.expectRevert(abi.encodeWithSelector(ModuleInactive.selector, MODULE_ID));
        h.encumberPosition(tokenIdTwo, POOL_ID, MODULE_ID, 1);

        vm.warp(5 days);
        h.accrueAum(keyTwo, POOL_ID, MODULE_ID);
        assertEq(h.principalOf(POOL_ID, keyTwo), 960, "other tuple should keep accruing after global deactivation");

        vm.prank(borrowerTwo);
        h.unencumberPosition(tokenIdTwo, POOL_ID, MODULE_ID, healthyEncumbered);
        assertEq(h.moduleEncumberedForModule(keyTwo, POOL_ID, MODULE_ID), 0, "other tuple should still be able to unencumber");

        token; // silence warning for tuple return readability
    }
}

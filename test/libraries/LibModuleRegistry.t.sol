// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";

contract LibModuleRegistryHarness {
    function setNextModuleId(uint256 nextModuleId) external {
        LibModuleRegistry.s().nextModuleId = nextModuleId;
    }

    function setGlobalKnobs(
        uint256 moduleCreationFee,
        uint16 defaultModuleAumBps,
        uint16 minModuleAumBps,
        uint16 maxModuleAumBps,
        uint16 deactivationGraceEpochs,
        bool moduleAciPaused
    ) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        ms.moduleCreationFee = moduleCreationFee;
        ms.defaultModuleAumBps = defaultModuleAumBps;
        ms.minModuleAumBps = minModuleAumBps;
        ms.maxModuleAumBps = maxModuleAumBps;
        ms.deactivationGraceEpochs = deactivationGraceEpochs;
        ms.moduleAciPaused = moduleAciPaused;
    }

    function setModule(
        uint256 moduleId,
        address owner,
        bytes32 metadataHash,
        bool paused,
        bool inactive,
        uint16 aumBps
    ) external {
        LibModuleRegistry.Module storage m = LibModuleRegistry.module(moduleId);
        m.owner = owner;
        m.metadataHash = metadataHash;
        m.paused = paused;
        m.inactive = inactive;
        m.aumBps = aumBps;
    }

    function setTupleAumState(
        bytes32 positionKey,
        uint256 poolId,
        uint256 moduleId,
        uint64 lastAumEpoch,
        bool delinquent,
        uint64 delinquentSince,
        uint256 lastShortfall
    ) external {
        LibModuleRegistry.TupleAumState storage st = LibModuleRegistry.tupleAumState(positionKey, poolId, moduleId);
        st.lastAumEpoch = lastAumEpoch;
        st.delinquent = delinquent;
        st.delinquentSince = delinquentSince;
        st.lastShortfall = lastShortfall;
    }

    function getModule(uint256 moduleId)
        external
        view
        returns (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps)
    {
        LibModuleRegistry.Module storage m = LibModuleRegistry.module(moduleId);
        return (m.owner, m.metadataHash, m.paused, m.inactive, m.aumBps);
    }

    function getGlobalKnobs()
        external
        view
        returns (
            uint256 nextModuleId,
            uint256 moduleCreationFee,
            uint16 defaultModuleAumBps,
            uint16 minModuleAumBps,
            uint16 maxModuleAumBps,
            uint16 deactivationGraceEpochs,
            bool moduleAciPaused
        )
    {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        return (
            ms.nextModuleId,
            ms.moduleCreationFee,
            ms.defaultModuleAumBps,
            ms.minModuleAumBps,
            ms.maxModuleAumBps,
            ms.deactivationGraceEpochs,
            ms.moduleAciPaused
        );
    }

    function getTupleAumState(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint64 lastAumEpoch, bool delinquent, uint64 delinquentSince, uint256 lastShortfall)
    {
        LibModuleRegistry.TupleAumState storage st = LibModuleRegistry.tupleAumState(positionKey, poolId, moduleId);
        return (st.lastAumEpoch, st.delinquent, st.delinquentSince, st.lastShortfall);
    }

    function emitModuleRegistered(uint256 moduleId, address owner, bytes32 metadataHash, uint16 aumBps) external {
        LibModuleRegistry.emitModuleRegistered(moduleId, owner, metadataHash, aumBps);
    }

    function emitModuleOwnerUpdated(uint256 moduleId, address oldOwner, address newOwner) external {
        LibModuleRegistry.emitModuleOwnerUpdated(moduleId, oldOwner, newOwner);
    }

    function emitModulePauseUpdated(uint256 moduleId, bool paused) external {
        LibModuleRegistry.emitModulePauseUpdated(moduleId, paused);
    }

    function emitModuleAumAccrued(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 epochs,
        uint256 feeDue,
        uint256 charged,
        uint256 shortfall,
        uint64 newLastAumEpoch
    ) external {
        LibModuleRegistry.emitModuleAumAccrued(
            moduleId, positionKey, poolId, epochs, feeDue, charged, shortfall, newLastAumEpoch
        );
    }

    function emitModuleAumDelinquent(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    ) external {
        LibModuleRegistry.emitModuleAumDelinquent(moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall);
    }

    function emitModulePermanentlyDeactivated(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    ) external {
        LibModuleRegistry.emitModulePermanentlyDeactivated(
            moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall
        );
    }

    function emitModuleAciPauseToggled(bool paused) external {
        LibModuleRegistry.emitModuleAciPauseToggled(paused);
    }
}

contract LibModuleRegistryTest is Test {
    event ModuleRegistered(uint256 indexed moduleId, address indexed owner, bytes32 metadataHash, uint16 aumBps);
    event ModuleOwnerUpdated(uint256 indexed moduleId, address indexed oldOwner, address indexed newOwner);
    event ModulePauseUpdated(uint256 indexed moduleId, bool paused);
    event ModuleAumAccrued(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 epochs,
        uint256 feeDue,
        uint256 charged,
        uint256 shortfall,
        uint64 newLastAumEpoch
    );
    event ModuleAumDelinquent(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    );
    event ModulePermanentlyDeactivated(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    );
    event ModuleAciPauseToggled(bool paused);

    LibModuleRegistryHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    uint256 internal constant MODULE_ID = 7;
    uint256 internal constant POOL_ID = 3;

    function setUp() public {
        h = new LibModuleRegistryHarness();
    }

    function test_storage_roundTrip_moduleGlobalAndTupleAum() public {
        h.setNextModuleId(12);
        h.setGlobalKnobs(1 ether, 75, 10, 300, 5, true);
        h.setModule(MODULE_ID, address(0xBEEF), keccak256("meta"), true, false, 222);
        h.setTupleAumState(POSITION_KEY, POOL_ID, MODULE_ID, 9 days, true, 8 days, 1234);

        (
            uint256 nextModuleId,
            uint256 moduleCreationFee,
            uint16 defaultModuleAumBps,
            uint16 minModuleAumBps,
            uint16 maxModuleAumBps,
            uint16 deactivationGraceEpochs,
            bool moduleAciPaused
        ) = h.getGlobalKnobs();
        assertEq(nextModuleId, 12);
        assertEq(moduleCreationFee, 1 ether);
        assertEq(defaultModuleAumBps, 75);
        assertEq(minModuleAumBps, 10);
        assertEq(maxModuleAumBps, 300);
        assertEq(deactivationGraceEpochs, 5);
        assertTrue(moduleAciPaused);

        (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps) = h.getModule(MODULE_ID);
        assertEq(owner, address(0xBEEF));
        assertEq(metadataHash, keccak256("meta"));
        assertTrue(paused);
        assertFalse(inactive);
        assertEq(aumBps, 222);

        (uint64 lastAumEpoch, bool delinquent, uint64 delinquentSince, uint256 lastShortfall) =
            h.getTupleAumState(POSITION_KEY, POOL_ID, MODULE_ID);
        assertEq(lastAumEpoch, uint64(9 days));
        assertTrue(delinquent);
        assertEq(delinquentSince, uint64(8 days));
        assertEq(lastShortfall, 1234);
    }

    function test_events_registrationOwnerPauseAndAciToggle() public {
        vm.expectEmit(true, true, false, true);
        emit ModuleRegistered(MODULE_ID, address(0xABCD), keccak256("m1"), 150);
        h.emitModuleRegistered(MODULE_ID, address(0xABCD), keccak256("m1"), 150);

        vm.expectEmit(true, true, true, true);
        emit ModuleOwnerUpdated(MODULE_ID, address(0xABCD), address(0xDCBA));
        h.emitModuleOwnerUpdated(MODULE_ID, address(0xABCD), address(0xDCBA));

        vm.expectEmit(true, false, false, true);
        emit ModulePauseUpdated(MODULE_ID, true);
        h.emitModulePauseUpdated(MODULE_ID, true);

        vm.expectEmit(false, false, false, true);
        emit ModuleAciPauseToggled(true);
        h.emitModuleAciPauseToggled(true);
    }

    function test_events_aumAccruedDelinquentAndDeactivated() public {
        vm.expectEmit(true, true, true, true);
        emit ModuleAumAccrued(MODULE_ID, POSITION_KEY, POOL_ID, 2, 100, 90, 10, uint64(2 days));
        h.emitModuleAumAccrued(MODULE_ID, POSITION_KEY, POOL_ID, 2, 100, 90, 10, uint64(2 days));

        vm.expectEmit(true, true, true, true);
        emit ModuleAumDelinquent(MODULE_ID, POSITION_KEY, POOL_ID, 100, 90, 10);
        h.emitModuleAumDelinquent(MODULE_ID, POSITION_KEY, POOL_ID, 100, 90, 10);

        vm.expectEmit(true, true, true, true);
        emit ModulePermanentlyDeactivated(MODULE_ID, POSITION_KEY, POOL_ID, 100, 90, 10);
        h.emitModulePermanentlyDeactivated(MODULE_ID, POSITION_KEY, POOL_ID, 100, 90, 10);
    }
}

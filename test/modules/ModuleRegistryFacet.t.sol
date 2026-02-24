// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {
    ModuleRegistrationDisabled,
    ModuleIncorrectFee,
    ModuleNotFound,
    ModuleInactive,
    NotModuleOwner,
    InvalidModuleOwner,
    ModuleAumOutOfBounds,
    InvalidAumFeeBounds
} from "../../src/libraries/Errors.sol";

contract DummyOwner {}

contract ModuleRegistryFacetHarness is ModuleRegistryFacet {
    function setOwnerRaw(address owner) external {
        LibDiamond.diamondStorage().contractOwner = owner;
    }

    function setTimelockRaw(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function setTreasuryRaw(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setModuleInactiveRaw(uint256 moduleId, bool inactive) external {
        LibModuleRegistry.module(moduleId).inactive = inactive;
    }

    function getModule(uint256 moduleId)
        external
        view
        returns (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps)
    {
        LibModuleRegistry.Module storage m = LibModuleRegistry.module(moduleId);
        return (m.owner, m.metadataHash, m.paused, m.inactive, m.aumBps);
    }

    function getGlobals()
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
}

contract ModuleRegistryFacetTest is Test {
    event ModuleRegistered(uint256 indexed moduleId, address indexed owner, bytes32 metadataHash, uint16 aumBps);
    event ModuleOwnerUpdated(uint256 indexed moduleId, address indexed oldOwner, address indexed newOwner);
    event ModulePauseUpdated(uint256 indexed moduleId, bool paused);
    event ModuleAciPauseToggled(bool paused);

    ModuleRegistryFacetHarness internal facet;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant USER = address(0xCAFE);
    address internal constant OTHER = address(0xD00D);
    address payable internal constant TREASURY = payable(address(0xFEE));

    function setUp() public {
        facet = new ModuleRegistryFacetHarness();
        facet.setOwnerRaw(OWNER);
        facet.setTimelockRaw(TIMELOCK);
        facet.setTreasuryRaw(TREASURY);

        vm.prank(OWNER);
        facet.setModuleAumBounds(0, 500);
        vm.prank(OWNER);
        facet.setDefaultModuleAumBps(100);
    }

    function test_registerModule_nonGovernanceRevertsWhenCreationDisabled() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ModuleRegistrationDisabled.selector));
        facet.registerModule(keccak256("meta"));
    }

    function test_registerModule_governanceZeroFee_incrementsAndPersists() public {
        vm.expectEmit(true, true, false, true, address(facet));
        emit ModuleRegistered(1, OWNER, keccak256("m1"), 100);
        vm.prank(OWNER);
        uint256 id1 = facet.registerModule(keccak256("m1"));

        vm.expectEmit(true, true, false, true, address(facet));
        emit ModuleRegistered(2, TIMELOCK, keccak256("m2"), 100);
        vm.prank(TIMELOCK);
        uint256 id2 = facet.registerModule(keccak256("m2"));

        assertEq(id1, 1);
        assertEq(id2, 2);

        (address owner1, bytes32 metadataHash1, bool paused1, bool inactive1, uint16 aumBps1) = facet.getModule(id1);
        assertEq(owner1, OWNER);
        assertEq(metadataHash1, keccak256("m1"));
        assertFalse(paused1);
        assertFalse(inactive1);
        assertEq(aumBps1, 100);

        (uint256 nextModuleId,,,,,,) = facet.getGlobals();
        assertEq(nextModuleId, 3);
    }

    function test_registerModule_nonGovernanceRequiresExactFeeAndRoutesTreasury() public {
        uint256 fee = 0.25 ether;
        vm.prank(OWNER);
        facet.setModuleCreationFee(fee);

        vm.deal(USER, 1 ether);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(ModuleIncorrectFee.selector, fee - 1, fee));
        facet.registerModule{value: fee - 1}(keccak256("m3"));

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(USER);
        uint256 moduleId = facet.registerModule{value: fee}(keccak256("m3"));
        assertEq(moduleId, 1);
        assertEq(TREASURY.balance, treasuryBefore + fee);
        (address moduleOwner,,,,) = facet.getModule(moduleId);
        assertEq(moduleOwner, USER);
    }

    function test_registerModule_governanceCannotSendValue() public {
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleIncorrectFee.selector, 1, 0));
        facet.registerModule{value: 1}(keccak256("m4"));
    }

    function test_setModuleOwner_onlyCurrentOwner() public {
        vm.prank(OWNER);
        uint256 moduleId = facet.registerModule(keccak256("m5"));

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotModuleOwner.selector, moduleId, OTHER));
        facet.setModuleOwner(moduleId, OTHER);

        address newOwner = address(new DummyOwner());
        vm.expectEmit(true, true, true, true, address(facet));
        emit ModuleOwnerUpdated(moduleId, OWNER, newOwner);
        vm.prank(OWNER);
        facet.setModuleOwner(moduleId, newOwner);

        (address ownerAfter,,,,) = facet.getModule(moduleId);
        assertEq(ownerAfter, newOwner);
    }

    function test_setModuleOwner_revertsForZeroAddress() public {
        vm.prank(OWNER);
        uint256 moduleId = facet.registerModule(keccak256("m5-zero"));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InvalidModuleOwner.selector, address(0)));
        facet.setModuleOwner(moduleId, address(0));

        (address ownerAfterReject,,,,) = facet.getModule(moduleId);
        assertEq(ownerAfterReject, OWNER, "rejected zero-address update must keep existing owner");

        address newOwner = address(new DummyOwner());
        vm.prank(OWNER);
        facet.setModuleOwner(moduleId, newOwner);
        (address ownerAfterValidTransfer,,,,) = facet.getModule(moduleId);
        assertEq(ownerAfterValidTransfer, newOwner, "valid owner transfer should still work after rejection");
    }

    function test_pauseUnpause_ownerAndGovernance_withInactiveNoReactivation() public {
        vm.prank(OWNER);
        uint256 moduleId = facet.registerModule(keccak256("m6"));

        vm.expectEmit(true, false, false, true, address(facet));
        emit ModulePauseUpdated(moduleId, true);
        vm.prank(OWNER);
        facet.pauseModule(moduleId);
        (,, bool paused1,,) = facet.getModule(moduleId);
        assertTrue(paused1);

        vm.expectEmit(true, false, false, true, address(facet));
        emit ModulePauseUpdated(moduleId, false);
        vm.prank(TIMELOCK);
        facet.unpauseModule(moduleId);
        (,, bool paused2,,) = facet.getModule(moduleId);
        assertFalse(paused2);

        facet.setModuleInactiveRaw(moduleId, true);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(ModuleInactive.selector, moduleId));
        facet.unpauseModule(moduleId);
    }

    function test_pauseRevertsForUnauthorized() public {
        vm.prank(OWNER);
        uint256 moduleId = facet.registerModule(keccak256("m7"));

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotModuleOwner.selector, moduleId, OTHER));
        facet.pauseModule(moduleId);
    }

    function test_setters_governanceOnly() public {
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setModuleCreationFee(1 ether);

        vm.prank(TIMELOCK);
        facet.setModuleCreationFee(1 ether);
        vm.prank(TIMELOCK);
        facet.setModuleDeactivationGraceEpochs(7);

        vm.expectEmit(false, false, false, true, address(facet));
        emit ModuleAciPauseToggled(true);
        vm.prank(TIMELOCK);
        facet.setModuleAciPaused(true);

        (, uint256 moduleCreationFee,,,, uint16 graceEpochs, bool moduleAciPaused) = facet.getGlobals();
        assertEq(moduleCreationFee, 1 ether);
        assertEq(graceEpochs, 7);
        assertTrue(moduleAciPaused);
    }

    function test_setModuleAumBoundsAndSetters_enforceBounds() public {
        vm.prank(OWNER);
        facet.setModuleAumBounds(50, 200);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleAumOutOfBounds.selector, uint16(25), uint16(50), uint16(200)));
        facet.setDefaultModuleAumBps(25);

        vm.prank(OWNER);
        facet.setDefaultModuleAumBps(100);
        vm.prank(OWNER);
        uint256 moduleId = facet.registerModule(keccak256("m8"));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleAumOutOfBounds.selector, uint16(250), uint16(50), uint16(200)));
        facet.setModuleAumBps(moduleId, 250);

        vm.prank(OWNER);
        facet.setModuleAumBps(moduleId, 150);
        (,,,, uint16 moduleBps) = facet.getModule(moduleId);
        assertEq(moduleBps, 150);
    }

    function test_setModuleAumBounds_invalidRangeReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InvalidAumFeeBounds.selector));
        facet.setModuleAumBounds(300, 200);
    }

    function test_moduleNotFound_checks() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 1));
        facet.pauseModule(1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 99));
        facet.setModuleAumBps(99, 10);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    InsufficientUnencumberedPrincipal,
    ModuleInactive,
    ModuleNotFound,
    ModulePausedError,
    NotNFTOwner
} from "../../src/libraries/Errors.sol";

contract ModuleGatewayFacetHarness is ModuleGatewayFacet {
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

    function setModule(uint256 moduleId, address owner, bool paused, bool inactive, uint16 aumBps) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = owner;
        m.paused = paused;
        m.inactive = inactive;
        m.aumBps = aumBps;
    }

    function setModulePaused(uint256 moduleId, bool paused) external {
        LibModuleRegistry.module(moduleId).paused = paused;
    }

    function setModuleInactive(uint256 moduleId, bool inactive) external {
        LibModuleRegistry.module(moduleId).inactive = inactive;
    }

    function setModuleAciPaused(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
    }

    function setModuleEncumbered(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        if (amount == 0) return;
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function setPoolMembership(bytes32 positionKey, uint256 poolId) external {
        LibPoolMembership._joinPool(positionKey, poolId);
    }

    function moduleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function moduleEncumberedByModule(bytes32 positionKey, uint256 poolId, uint256 moduleId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function principalOf(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function activeCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function trackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }

    function canClearMembership(bytes32 positionKey, uint256 poolId) external view returns (bool canClear, string memory reason) {
        return LibPoolMembership.canClearMembership(positionKey, poolId);
    }
}

contract ModuleGatewayFacetTest is Test {
    ModuleGatewayFacetHarness internal facet;
    PositionNFT internal nft;
    MockERC20 internal token;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant MODULE_OWNER = address(0xCAFE);
    address internal constant TREASURY = address(0xFEE);

    uint256 internal constant POOL_ID = 11;
    uint256 internal constant MODULE_ID = 1;
    uint256 internal constant TOKEN_ID = 1;

    bytes32 internal positionKey;

    function setUp() public {
        facet = new ModuleGatewayFacetHarness();

        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(TOKEN_ID);

        token = new MockERC20("Mock", "MOCK", 18, 0);
        facet.setupErc20Pool(POOL_ID, address(token), 1_000_000, 1_000_000);
        facet.setPrincipal(POOL_ID, positionKey, 1_000_000);
        facet.setTreasury(TREASURY);
        facet.setFeeSplits(10_000, 0);
        token.mint(address(facet), 1_000_000);

        facet.setModule(MODULE_ID, MODULE_OWNER, false, false, 100);
        facet.setPoolMembership(positionKey, POOL_ID);
    }

    function test_encumber_revertsForUnknownPausedAndInactiveModules() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 99));
        facet.encumberPosition(TOKEN_ID, POOL_ID, 99, 1);

        facet.setModulePaused(MODULE_ID, true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 1);

        facet.setModulePaused(MODULE_ID, false);
        facet.setModuleInactive(MODULE_ID, true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleInactive.selector, MODULE_ID));
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 1);
    }

    function test_encumberAndUnencumber_requirePositionOwner() public {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, OTHER, TOKEN_ID));
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 10);

        vm.prank(OWNER);
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 10);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, OTHER, TOKEN_ID));
        facet.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 1);
    }

    function test_poke_permissionless_andCallableWhenPausedOrInactive() public {
        facet.setPrincipal(POOL_ID, positionKey, 365_050);
        facet.setModuleEncumbered(positionKey, POOL_ID, MODULE_ID, 365_000);

        facet.setModulePaused(MODULE_ID, true);

        vm.warp(1 days);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID); // first-touch checkpoint only

        vm.warp(2 days);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID);
        assertEq(facet.principalOf(POOL_ID, positionKey), 365_040);

        facet.setModuleInactive(MODULE_ID, true);
        vm.warp(3 days);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID);
        assertEq(facet.principalOf(POOL_ID, positionKey), 365_030);
    }

    function test_encumber_accruesAumBeforeAvailabilityCheck() public {
        facet.setPrincipal(POOL_ID, positionKey, 365_050);
        facet.setModuleEncumbered(positionKey, POOL_ID, MODULE_ID, 365_000);

        vm.warp(1 days);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID); // init checkpoint

        vm.warp(2 days);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InsufficientUnencumberedPrincipal.selector, 45, 40));
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 45);
    }

    function test_encumber_aciIncreaseGatedByGlobalPause() public {
        vm.prank(OWNER);
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 100);
        assertEq(facet.activeCreditPrincipalTotal(POOL_ID), 100);

        ModuleGatewayFacetHarness facet2 = new ModuleGatewayFacetHarness();
        facet2.setPositionNFT(address(nft));
        facet2.setupErc20Pool(POOL_ID, address(token), 1_000_000, 1_000_000);
        facet2.setPrincipal(POOL_ID, positionKey, 1_000_000);
        facet2.setTreasury(TREASURY);
        facet2.setFeeSplits(10_000, 0);
        token.mint(address(facet2), 1_000_000);
        facet2.setModule(MODULE_ID, MODULE_OWNER, false, false, 100);
        facet2.setPoolMembership(positionKey, POOL_ID);
        facet2.setModuleAciPaused(true);

        vm.prank(OWNER);
        facet2.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 100);
        assertEq(facet2.activeCreditPrincipalTotal(POOL_ID), 0);
    }

    function test_unencumber_allowedForPausedAndInactive_andAlwaysDecreasesAci() public {
        vm.prank(OWNER);
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 120);
        assertEq(facet.activeCreditPrincipalTotal(POOL_ID), 120);
        assertEq(facet.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 120);

        facet.setModuleAciPaused(true);
        facet.setModulePaused(MODULE_ID, true);

        vm.prank(OWNER);
        facet.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 20);
        assertEq(facet.activeCreditPrincipalTotal(POOL_ID), 100);
        assertEq(facet.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 100);

        facet.setModulePaused(MODULE_ID, false);
        facet.setModuleInactive(MODULE_ID, true);

        vm.prank(OWNER);
        facet.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 30);
        assertEq(facet.activeCreditPrincipalTotal(POOL_ID), 70);
        assertEq(facet.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 70);
    }

    function test_unencumberAndPoke_revertForUnknownModule() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 404));
        facet.unencumberPosition(TOKEN_ID, POOL_ID, 404, 1);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 404));
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, 404);
    }

    function test_poke_sameEpoch_isNoOpAfterCheckpoint() public {
        facet.setPrincipal(POOL_ID, positionKey, 365_050);
        facet.setModuleEncumbered(positionKey, POOL_ID, MODULE_ID, 365_000);

        vm.warp(1 days);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID); // first touch checkpoint

        uint256 principalBefore = facet.principalOf(POOL_ID, positionKey);
        vm.prank(OTHER);
        facet.pokeModuleAum(TOKEN_ID, POOL_ID, MODULE_ID); // same epoch no-op
        uint256 principalAfter = facet.principalOf(POOL_ID, positionKey);
        assertEq(principalAfter, principalBefore);
    }

    function test_membershipCleanupBlocked_reasonModuleEncumbrance() public {
        vm.prank(OWNER);
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 10);
        facet.setPrincipal(POOL_ID, positionKey, 0);

        (bool canClear, string memory reason) = facet.canClearMembership(positionKey, POOL_ID);
        assertFalse(canClear);
        assertEq(reason, "module encumbrance");
    }

    function test_reservationOnlyEncumberUnencumber_doesNotChangeTrackedBacking() public {
        uint256 trackedBefore = facet.trackedBalance(POOL_ID);

        vm.prank(OWNER);
        facet.encumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 100);
        assertEq(facet.trackedBalance(POOL_ID), trackedBefore);

        vm.prank(OWNER);
        facet.unencumberPosition(TOKEN_ID, POOL_ID, MODULE_ID, 40);
        assertEq(facet.trackedBalance(POOL_ID), trackedBefore);
    }
}

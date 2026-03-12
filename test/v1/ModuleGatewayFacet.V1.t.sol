// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {
    EncumbranceUnderflow,
    InvalidTokenId,
    InsufficientUnencumberedPrincipal,
    ModuleInactive,
    ModuleNotFound,
    ModulePausedError,
    NotNFTOwner,
    PoolMembershipRequired,
    PoolNotInitialized
} from "../../src/libraries/Errors.sol";

contract LocalModuleGatewayMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ModuleGatewayV1Harness is ModuleGatewayFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address token, uint256 trackedAmount, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = token;
        p.trackedBalance = trackedAmount;
        p.totalDeposits = totalDeposits;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
    }

    function setPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }

    function setModule(uint256 moduleId, address owner, bool paused, bool inactive, uint256 aumBps) external {
        if (aumBps > type(uint16).max) revert();
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = owner;
        m.paused = paused;
        m.inactive = inactive;
        m.aumBps = uint16(aumBps);
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

    function joinPool(bytes32 positionKey, uint256 poolId) external {
        LibPoolMembership._joinPool(positionKey, poolId);
    }

    function forceLeavePool(bytes32 positionKey, uint256 poolId) external {
        LibPoolMembership._leavePool(positionKey, poolId, true, "test");
    }

    function moduleEncumberedByModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256)
    {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function activeCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function principalOf(uint256 poolId, bytes32 key) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[key];
    }

    function moduleAciPaused() external view returns (bool) {
        return LibModuleRegistry.s().moduleAciPaused;
    }

    function getTupleAumState(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint64 lastAumEpoch, bool delinquent, uint64 delinquentSince, uint256 lastShortfall)
    {
        LibModuleRegistry.TupleAumState storage tuple = LibModuleRegistry.s().tupleAum[positionKey][poolId][moduleId];
        return (tuple.lastAumEpoch, tuple.delinquent, tuple.delinquentSince, tuple.lastShortfall);
    }
}

contract ModuleGatewayFacetV1Test is Test {
    ModuleGatewayV1Harness internal harness;
    PositionNFT internal nft;
    LocalModuleGatewayMockERC20V1 internal token;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant MODULE_OWNER = address(0xCAFE);

    uint256 internal constant POOL_ID = 11;
    uint256 internal constant MODULE_ID = 1;

    uint256 internal tokenId;
    bytes32 internal positionKey;

    function setUp() public {
        harness = new ModuleGatewayV1Harness();

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        token = new LocalModuleGatewayMockERC20V1("Mock", "MOCK", 18);

        tokenId = nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(tokenId);

        harness.initPool(POOL_ID, address(token), 1_000_000 ether, 1_000_000 ether);
        harness.setPrincipal(POOL_ID, positionKey, 1_000 ether);
        harness.setModule(MODULE_ID, MODULE_OWNER, false, false, 0);
        harness.joinPool(positionKey, POOL_ID);
    }

    function test_encumber_revertsForUnknownPausedAndInactiveModules() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 99));
        harness.encumberPosition(tokenId, POOL_ID, 99, 1 ether);

        harness.setModulePaused(MODULE_ID, true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModulePausedError.selector, MODULE_ID));
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 1 ether);

        harness.setModulePaused(MODULE_ID, false);
        harness.setModuleInactive(MODULE_ID, true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleInactive.selector, MODULE_ID));
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 1 ether);
    }

    function test_encumberAndUnencumber_ownerAndAccounting() public {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, OTHER, tokenId));
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 100 ether);

        vm.prank(OWNER);
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 100 ether);
        assertEq(harness.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 100 ether);
        assertEq(harness.activeCreditPrincipalTotal(POOL_ID), 100 ether);

        vm.prank(OWNER);
        harness.unencumberPosition(tokenId, POOL_ID, MODULE_ID, 40 ether);
        assertEq(harness.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 60 ether);
        assertEq(harness.activeCreditPrincipalTotal(POOL_ID), 60 ether);
    }

    function test_encumber_respectsAvailablePrincipal_andAciPause() public {
        harness.setPrincipal(POOL_ID, positionKey, 30 ether);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(InsufficientUnencumberedPrincipal.selector, 50 ether, 30 ether));
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 50 ether);

        harness.setModuleAciPaused(true);
        vm.prank(OWNER);
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 20 ether);
        assertEq(harness.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_ID), 20 ether);
        assertEq(harness.activeCreditPrincipalTotal(POOL_ID), 0);
    }

    function test_unencumber_revertsForOverdrawAndUnknownModule() public {
        vm.prank(OWNER);
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 100 ether);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 101 ether, 100 ether));
        harness.unencumberPosition(tokenId, POOL_ID, MODULE_ID, 101 ether);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 99));
        harness.unencumberPosition(tokenId, POOL_ID, 99, 1 ether);
    }

    function test_unencumber_revertsForOwnershipAndMembership() public {
        vm.prank(OWNER);
        harness.encumberPosition(tokenId, POOL_ID, MODULE_ID, 100 ether);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, OTHER, tokenId));
        harness.unencumberPosition(tokenId, POOL_ID, MODULE_ID, 10 ether);

        harness.forceLeavePool(positionKey, POOL_ID);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, positionKey, POOL_ID));
        harness.unencumberPosition(tokenId, POOL_ID, MODULE_ID, 10 ether);
    }

    function test_pokeModuleAum_updatesTupleStateWithoutUnexpectedPrincipalMutation() public {
        harness.setModule(MODULE_ID, MODULE_OWNER, false, false, 500);
        uint256 principalBefore = harness.principalOf(POOL_ID, positionKey);

        vm.prank(OTHER);
        harness.pokeModuleAum(tokenId, POOL_ID, MODULE_ID);

        (uint64 lastEpoch, bool delinquent, uint64 delinquentSince, uint256 shortfall) =
            harness.getTupleAumState(positionKey, POOL_ID, MODULE_ID);
        uint64 firstEpoch = lastEpoch;
        assertFalse(delinquent);
        assertEq(delinquentSince, 0);
        assertEq(shortfall, 0);
        assertEq(harness.principalOf(POOL_ID, positionKey), principalBefore);

        vm.warp(block.timestamp + 2 days + 1 hours);
        vm.prank(OTHER);
        harness.pokeModuleAum(tokenId, POOL_ID, MODULE_ID);

        (lastEpoch, delinquent, delinquentSince, shortfall) = harness.getTupleAumState(positionKey, POOL_ID, MODULE_ID);
        assertGt(lastEpoch, firstEpoch);
        assertEq(uint256(lastEpoch) % 1 days, 0);
        assertFalse(delinquent);
        assertEq(delinquentSince, 0);
        assertEq(shortfall, 0);
        assertEq(harness.principalOf(POOL_ID, positionKey), principalBefore);
    }

    function test_pokeModuleAum_revertsForUnknownModuleInvalidPoolAndPosition() public {
        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 99));
        harness.pokeModuleAum(tokenId, POOL_ID, 99);

        vm.expectRevert(abi.encodeWithSelector(PoolNotInitialized.selector, 999));
        harness.pokeModuleAum(tokenId, 999, MODULE_ID);

        vm.expectRevert(abi.encodeWithSelector(InvalidTokenId.selector, 999_999));
        harness.pokeModuleAum(999_999, POOL_ID, MODULE_ID);
    }
}

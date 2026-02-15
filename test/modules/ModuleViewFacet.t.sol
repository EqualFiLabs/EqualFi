// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {ModuleViewFacet} from "../../src/modules/ModuleViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../../src/libraries/LibModuleRegistry.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {ModuleNotFound} from "../../src/libraries/Errors.sol";

contract ModuleViewFacetHarness is ModuleViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function setupPool(uint256 pid) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = address(0x1234);
    }

    function setModule(
        uint256 moduleId,
        address owner,
        bytes32 metadataHash,
        bool paused,
        bool inactive,
        uint16 aumBps
    ) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        if (ms.nextModuleId <= moduleId) {
            ms.nextModuleId = moduleId + 1;
        }
        LibModuleRegistry.Module storage m = ms.modules[moduleId];
        m.owner = owner;
        m.metadataHash = metadataHash;
        m.paused = paused;
        m.inactive = inactive;
        m.aumBps = aumBps;
    }

    function setModuleAumConfig(uint16 defaultBps, uint16 minBps, uint16 maxBps, uint16 graceEpochs) external {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        ms.defaultModuleAumBps = defaultBps;
        ms.minModuleAumBps = minBps;
        ms.maxModuleAumBps = maxBps;
        ms.deactivationGraceEpochs = graceEpochs;
    }

    function setModuleAciPausedRaw(bool paused) external {
        LibModuleRegistry.s().moduleAciPaused = paused;
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

    function setModuleEncumbered(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        if (amount == 0) return;
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }
}

contract ModuleViewFacetTest is Test {
    ModuleViewFacetHarness internal facet;
    PositionNFT internal nft;
    address internal constant OWNER = address(0xA11CE);

    uint256 internal constant POOL_ID = 11;
    uint256 internal constant MODULE_ID_1 = 1;
    uint256 internal constant MODULE_ID_2 = 2;
    uint256 internal constant TOKEN_ID = 1;

    bytes32 internal positionKey;

    function setUp() public {
        facet = new ModuleViewFacetHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(TOKEN_ID);

        facet.setupPool(POOL_ID);
        facet.setModuleAumConfig(100, 10, 500, 2);
        facet.setModule(MODULE_ID_1, address(0xA11CE), keccak256("module-1"), false, false, 75);
        facet.setModule(MODULE_ID_2, address(0xBEEF), keccak256("module-2"), true, false, 120);
    }

    function test_getModule_returnsConfigAndUnknownReverts() public {
        (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps) = facet.getModule(MODULE_ID_1);
        assertEq(owner, address(0xA11CE));
        assertEq(metadataHash, keccak256("module-1"));
        assertFalse(paused);
        assertFalse(inactive);
        assertEq(aumBps, 75);

        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 999));
        facet.getModule(999);
    }

    function test_encumbranceViews_totalAndPerModule() public {
        facet.setModuleEncumbered(positionKey, POOL_ID, MODULE_ID_1, 40);
        facet.setModuleEncumbered(positionKey, POOL_ID, MODULE_ID_2, 60);

        uint256 total = facet.getModuleEncumbrance(TOKEN_ID, POOL_ID);
        uint256 m1 = facet.getModuleEncumbranceForModule(TOKEN_ID, POOL_ID, MODULE_ID_1);
        uint256 m2 = facet.getModuleEncumbranceForModule(TOKEN_ID, POOL_ID, MODULE_ID_2);

        assertEq(total, 100);
        assertEq(m1, 40);
        assertEq(m2, 60);

        vm.expectRevert(abi.encodeWithSelector(ModuleNotFound.selector, 404));
        facet.getModuleEncumbranceForModule(TOKEN_ID, POOL_ID, 404);
    }

    function test_getModuleAumState_returnsShortfallAndGraceProgress() public {
        facet.setTupleAumState(positionKey, POOL_ID, MODULE_ID_1, uint64(1 days), true, uint64(1 days), 77);

        vm.warp(4 days + 7 hours);
        (
            uint64 lastAccruedEpoch,
            uint256 pendingEpochs_,
            bool delinquent,
            uint64 delinquentSince,
            uint256 lastShortfall,
            uint16 graceEpochs,
            uint256 delinquentEpochs_,
            bool graceSatisfied
        ) = facet.getModuleAumState(TOKEN_ID, POOL_ID, MODULE_ID_1);

        assertEq(lastAccruedEpoch, 1 days);
        assertEq(pendingEpochs_, 3);
        assertTrue(delinquent);
        assertEq(delinquentSince, 1 days);
        assertEq(lastShortfall, 77);
        assertEq(graceEpochs, 2);
        assertEq(delinquentEpochs_, 3);
        assertTrue(graceSatisfied);
    }

    function test_globalAumConfigAndAciPauseView() public {
        (uint16 defaultBps, uint16 minBps, uint16 maxBps, uint16 graceEpochs) = facet.getModuleAumConfig();
        assertEq(defaultBps, 100);
        assertEq(minBps, 10);
        assertEq(maxBps, 500);
        assertEq(graceEpochs, 2);

        assertFalse(facet.isModuleAciPaused());
        facet.setModuleAciPausedRaw(true);
        assertTrue(facet.isModuleAciPaused());
    }
}

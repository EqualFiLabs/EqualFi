// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PositionNFT} from "../../../src/nft/PositionNFT.sol";
import {ModuleGatewayFacet} from "../../../src/modules/ModuleGatewayFacet.sol";
import {LibAppStorage} from "../../../src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../../../src/libraries/LibEncumbrance.sol";
import {LibModuleRegistry} from "../../../src/libraries/LibModuleRegistry.sol";
import {LibPoolMembership} from "../../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../../src/libraries/Types.sol";

contract LocalModuleInvariantMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract ModuleGatewayInvariantV1Harness is ModuleGatewayFacet {
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

    function moduleAciPaused() external view returns (bool) {
        return LibModuleRegistry.s().moduleAciPaused;
    }

    function joinPool(bytes32 positionKey, uint256 poolId) external {
        LibPoolMembership._joinPool(positionKey, poolId);
    }

    function principalOf(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function activeCreditPrincipalTotal(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal;
    }

    function moduleEncumberedByModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256)
    {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function moduleEncumberedTotal(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }
}

contract ModuleGatewayStatefulHandler is Test {
    ModuleGatewayInvariantV1Harness internal harness;
    address internal owner;
    uint256 internal tokenId;
    uint256 internal poolId;
    uint256 internal moduleIdA;
    uint256 internal moduleIdB;
    uint256 internal aciPausedCeiling_;

    constructor(
        ModuleGatewayInvariantV1Harness harness_,
        address owner_,
        uint256 tokenId_,
        uint256 poolId_,
        uint256 moduleIdA_,
        uint256 moduleIdB_
    ) {
        harness = harness_;
        owner = owner_;
        tokenId = tokenId_;
        poolId = poolId_;
        moduleIdA = moduleIdA_;
        moduleIdB = moduleIdB_;
        aciPausedCeiling_ = harness.activeCreditPrincipalTotal(poolId_);
    }

    function encumberA(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 500 ether);
        _encumber(moduleIdA, amount);
    }

    function encumberB(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 500 ether);
        _encumber(moduleIdB, amount);
    }

    function unencumberA(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 500 ether);
        _unencumber(moduleIdA, amount);
    }

    function unencumberB(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 500 ether);
        _unencumber(moduleIdB, amount);
    }

    function _encumber(uint256 moduleId, uint256 amount) internal {
        uint256 beforeModule = harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId);
        uint256 beforeAci = harness.activeCreditPrincipalTotal(poolId);
        bool aciPaused = harness.moduleAciPaused();
        vm.prank(owner);
        try harness.encumberPosition(tokenId, poolId, moduleId, amount) {
            uint256 afterModule = harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId);
            uint256 afterAci = harness.activeCreditPrincipalTotal(poolId);
            uint256 delta = afterModule - beforeModule;
            if (aciPaused) {
                assertEq(afterAci, beforeAci);
            } else {
                assertEq(afterAci, beforeAci + delta);
            }
        } catch {
            assertEq(harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId), beforeModule);
            assertEq(harness.activeCreditPrincipalTotal(poolId), beforeAci);
        }
    }

    function _unencumber(uint256 moduleId, uint256 amount) internal {
        uint256 beforeModule = harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId);
        uint256 beforeAci = harness.activeCreditPrincipalTotal(poolId);
        vm.prank(owner);
        try harness.unencumberPosition(tokenId, poolId, moduleId, amount) {
            uint256 afterModule = harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId);
            uint256 delta = beforeModule - afterModule;
            uint256 expectedAci = beforeAci > delta ? beforeAci - delta : 0;
            assertEq(harness.activeCreditPrincipalTotal(poolId), expectedAci);
        } catch {
            assertEq(harness.moduleEncumberedByModule(_positionKey(), poolId, moduleId), beforeModule);
            assertEq(harness.activeCreditPrincipalTotal(poolId), beforeAci);
        }
    }

    function toggleModulePaused(uint256 seed) external {
        harness.setModulePaused((seed % 2) == 1 ? moduleIdA : moduleIdB, true);
        harness.setModulePaused((seed % 2) == 1 ? moduleIdB : moduleIdA, false);
    }

    function toggleModuleInactive(uint256 seed) external {
        harness.setModuleInactive((seed % 2) == 1 ? moduleIdA : moduleIdB, true);
        harness.setModuleInactive((seed % 2) == 1 ? moduleIdB : moduleIdA, false);
    }

    function toggleModuleAciPaused(uint256 seed) external {
        bool pauseAci = (seed % 2) == 1;
        harness.setModuleAciPaused(pauseAci);
        if (pauseAci) {
            aciPausedCeiling_ = harness.activeCreditPrincipalTotal(poolId);
        }
    }

    function _positionKey() internal view returns (bytes32) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
    }

    function aciPausedCeiling() external view returns (uint256) {
        return aciPausedCeiling_;
    }
}

contract ModuleGatewayStatefulInvariantV1Test is StdInvariant, Test {
    address internal constant OWNER = address(0xA11CE);
    uint256 internal constant POOL_ID = 11;
    uint256 internal constant MODULE_A_ID = 1;
    uint256 internal constant MODULE_B_ID = 2;
    uint256 internal constant PRINCIPAL = 1_000 ether;

    ModuleGatewayInvariantV1Harness internal harness;
    ModuleGatewayStatefulHandler internal handler;
    PositionNFT internal nft;
    LocalModuleInvariantMockERC20V1 internal token;

    uint256 internal tokenId;
    bytes32 internal positionKey;

    function setUp() public {
        harness = new ModuleGatewayInvariantV1Harness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        token = new LocalModuleInvariantMockERC20V1("Mock", "MOCK", 18);

        tokenId = nft.mint(OWNER, POOL_ID);
        positionKey = nft.getPositionKey(tokenId);

        harness.initPool(POOL_ID, address(token), 1_000_000 ether, 1_000_000 ether);
        harness.setPrincipal(POOL_ID, positionKey, PRINCIPAL);
        harness.setModule(MODULE_A_ID, address(0xCAFE), false, false, 0);
        harness.setModule(MODULE_B_ID, address(0xFACE), false, false, 0);
        harness.joinPool(positionKey, POOL_ID);

        handler = new ModuleGatewayStatefulHandler(harness, OWNER, tokenId, POOL_ID, MODULE_A_ID, MODULE_B_ID);
        targetContract(address(handler));
    }

    function invariant_moduleEncumbranceNeverExceedsPrincipal() public {
        uint256 encTotal = harness.moduleEncumberedTotal(positionKey, POOL_ID);
        assertLe(encTotal, harness.principalOf(POOL_ID, positionKey));
    }

    function invariant_activeCreditNotAboveModuleEncumbrance() public {
        uint256 encTotal = harness.moduleEncumberedTotal(positionKey, POOL_ID);
        assertLe(harness.activeCreditPrincipalTotal(POOL_ID), encTotal);
    }

    function invariant_moduleTotalsRemainConsistentAcrossModules() public {
        uint256 encA = harness.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_A_ID);
        uint256 encB = harness.moduleEncumberedByModule(positionKey, POOL_ID, MODULE_B_ID);
        uint256 encTotal = harness.moduleEncumberedTotal(positionKey, POOL_ID);
        assertGe(encTotal, encA);
        assertGe(encTotal, encB);
        assertEq(encTotal, encA + encB);
    }

    function invariant_activeCreditDoesNotIncreaseWhileAciPaused() public {
        if (harness.moduleAciPaused()) {
            assertLe(harness.activeCreditPrincipalTotal(POOL_ID), handler.aciPausedCeiling());
        }
    }

    function invariant_zeroEncumbranceImpliesZeroActiveCredit() public {
        uint256 encTotal = harness.moduleEncumberedTotal(positionKey, POOL_ID);
        if (encTotal == 0) {
            assertEq(harness.activeCreditPrincipalTotal(POOL_ID), 0);
        }
    }
}

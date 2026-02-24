// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexFeePotDilutionHarness is EqualIndexActionsFacetV3 {
    function initIndex(
        uint256 indexId,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16[] memory mintFeeBps,
        uint16[] memory burnFeeBps,
        uint16 flashFeeBps,
        address token
    ) external {
        Index storage idx = s().indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = mintFeeBps;
        idx.burnFeeBps = burnFeeBps;
        idx.flashFeeBps = flashFeeBps;
        idx.token = token;
        if (s().indexCount <= indexId) {
            s().indexCount = indexId + 1;
        }
    }

    function setAssetPool(address asset, uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setTreasury(address treasury, uint16 shareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareConfigured = true;
        store.treasuryShareBps = shareBps;
    }

    function setActiveCreditShare(uint16 shareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.activeCreditShareConfigured = true;
        store.activeCreditShareBps = shareBps;
    }

    function previewMintInputs(uint256 indexId, uint256 units) external view returns (uint256[] memory maxInputs) {
        Index storage idx = s().indexes[indexId];
        uint256 len = idx.assets.length;
        uint256 totalSupply = idx.totalUnits;
        maxInputs = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            uint256 need;
            uint256 potBuyIn;
            if (totalSupply == 0) {
                need = Math.mulDiv(idx.bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            } else {
                need = Math.mulDiv(s().vaultBalances[indexId][asset], units, totalSupply, Math.Rounding.Ceil);
                potBuyIn = Math.mulDiv(s().feePots[indexId][asset], units, totalSupply, Math.Rounding.Ceil);
            }
            uint256 grossIn = need + potBuyIn;
            uint256 fee = Math.mulDiv(grossIn, idx.mintFeeBps[i], 10_000, Math.Rounding.Ceil);
            maxInputs[i] = grossIn + fee;
        }
    }
}

contract EqualIndexFeePotDilutionTest is Test {
    EqualIndexFeePotDilutionHarness internal facet;
    MockERC20 internal token;
    address internal victim = address(0xA11CE);
    address internal attacker = address(0xBEEF);
    uint256 internal constant SCALE = 1e18;

    function setUp() public {
        facet = new EqualIndexFeePotDilutionHarness();
        token = new MockERC20("Asset", "AST", 18, 0);

        // Keep pool-share routing internal to simplify deterministic balance checks.
        facet.setTreasury(address(0), 0);
        facet.setActiveCreditShare(0);
        facet.setAssetPool(address(token), 1, 1_000_000 ether, 1_000_000 ether);

        token.mint(victim, 1_000_000 ether);
        token.mint(attacker, 1_000_000 ether);
        vm.prank(victim);
        token.approve(address(facet), type(uint256).max);
        vm.prank(attacker);
        token.approve(address(facet), type(uint256).max);
    }

    function test_feePotAttackRoundTripCannotDiluteVictimOrExtractValue() public {
        uint256 victimInitialUnits = 10 * SCALE;
        uint256 victimBurnUnits = 5 * SCALE;
        uint256 attackerUnits = 5 * SCALE;

        uint256 baselineIndexId = _createIndex(0, 1 ether, 100, 100);
        _mintAs(victim, baselineIndexId, victimInitialUnits, victim);
        vm.prank(victim);
        uint256 baselineVictimOut = facet.burn(baselineIndexId, victimBurnUnits, victim)[0];

        uint256 attackIndexId = _createIndex(1, 1 ether, 100, 100);
        _mintAs(victim, attackIndexId, victimInitialUnits, victim);

        uint256 attackerBefore = token.balanceOf(attacker);
        _mintAs(attacker, attackIndexId, attackerUnits, attacker);
        vm.prank(attacker);
        facet.burn(attackIndexId, attackerUnits, attacker);
        uint256 attackerAfter = token.balanceOf(attacker);

        vm.prank(victim);
        uint256 victimOutAfterAttack = facet.burn(attackIndexId, victimBurnUnits, victim)[0];

        // Attacker should not extract positive value from mint->burn around existing fee pot.
        assertLe(attackerAfter, attackerBefore + 1, "attacker extracted value");
        // Victim should not be economically diluted by attacker round-trip (allow 1 wei rounding noise).
        assertGe(victimOutAfterAttack + 1, baselineVictimOut, "victim diluted by attacker round-trip");
    }

    function test_adversarialOrderingChangesVictimBurnOutcome() public {
        uint256 victimInitialUnits = 10 * SCALE;
        uint256 victimBurnUnits = 5 * SCALE;
        uint256 attackerUnits = 5 * SCALE;

        uint256 victimFirstIndexId = _createIndex(2, 1 ether, 100, 100);
        _mintAs(victim, victimFirstIndexId, victimInitialUnits, victim);
        vm.prank(victim);
        uint256 victimBurnFirstOut = facet.burn(victimFirstIndexId, victimBurnUnits, victim)[0];
        _mintAs(attacker, victimFirstIndexId, attackerUnits, attacker);
        vm.prank(attacker);
        facet.burn(victimFirstIndexId, attackerUnits, attacker);

        uint256 attackerFirstIndexId = _createIndex(3, 1 ether, 100, 100);
        _mintAs(victim, attackerFirstIndexId, victimInitialUnits, victim);
        _mintAs(attacker, attackerFirstIndexId, attackerUnits, attacker);
        vm.prank(attacker);
        facet.burn(attackerFirstIndexId, attackerUnits, attacker);
        vm.prank(victim);
        uint256 attackerBurnFirstOut = facet.burn(attackerFirstIndexId, victimBurnUnits, victim)[0];

        // Explicitly lock in sequencing sensitivity while no minOut/deadline burn guard exists.
        assertTrue(victimBurnFirstOut != attackerBurnFirstOut, "burn outcome should be ordering-sensitive");
    }

    function _createIndex(uint256 indexId, uint256 bundleAmount, uint16 mintFeeBps, uint16 burnFeeBps)
        internal
        returns (uint256)
    {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = bundleAmount;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = mintFeeBps;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = burnFeeBps;

        IndexToken idxToken = new IndexToken("Index", "IDX", address(facet), assets, bundles, 0, indexId);
        facet.initIndex(indexId, assets, bundles, mintFees, burnFees, 0, address(idxToken));
        return indexId;
    }

    function _mintAs(address user, uint256 indexId, uint256 units, address to) internal {
        vm.startPrank(user);
        uint256[] memory maxInputs = facet.previewMintInputs(indexId, units);
        facet.mint(indexId, units, to, maxInputs);
        vm.stopPrank();
    }
}

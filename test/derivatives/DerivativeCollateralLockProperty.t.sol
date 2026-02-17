// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {
    LibDerivativeHelpers,
    DerivativeError_InvalidAmount,
    DerivativeError_InsufficientPrincipal
} from "../../src/libraries/LibDerivativeHelpers.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Property: Collateral lock on creation
/// @notice Validates: Requirements 2.1, 3.2, 6.2, 6.3, 9.2
/// forge-config: default.fuzz.runs = 100
contract DerivativeCollateralLockPropertyTest is Test {
    DerivativeHelpersHarness internal harness;

    function setUp() public {
        harness = new DerivativeHelpersHarness();
    }

    function testProperty_CollateralLockOnCreation(
        uint256 principal,
        uint256 locked,
        uint256 lent,
        uint256 directOfferEscrow,
        uint256 indexEncumbered,
        uint256 moduleEncumbered,
        uint256 amount
    ) public {
        principal = bound(principal, 0, type(uint96).max);
        locked = bound(locked, 0, type(uint96).max);
        lent = bound(lent, 0, type(uint96).max);
        directOfferEscrow = bound(directOfferEscrow, 0, type(uint96).max);
        indexEncumbered = bound(indexEncumbered, 0, type(uint96).max);
        moduleEncumbered = bound(moduleEncumbered, 0, type(uint96).max);
        amount = bound(amount, 0, type(uint96).max);

        uint256 poolId = 1;
        bytes32 positionKey =
            keccak256(abi.encodePacked(principal, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered, amount));

        harness.seedPool(poolId, positionKey, principal);
        harness.setEncumbranceState(positionKey, poolId, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered);

        uint256 available = _available(principal, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered);

        if (amount == 0) {
            vm.expectRevert(abi.encodeWithSelector(DerivativeError_InvalidAmount.selector, 0));
            harness.lockCollateral(positionKey, poolId, amount);
            return;
        }

        if (amount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    DerivativeError_InsufficientPrincipal.selector,
                    available,
                    amount
                )
            );
            harness.lockCollateral(positionKey, poolId, amount);
            return;
        }

        harness.lockCollateral(positionKey, poolId, amount);
        assertEq(harness.getLocked(positionKey, poolId), locked + amount, "locked increases");
        assertEq(harness.getLent(positionKey, poolId), lent, "lent unchanged");
        assertEq(harness.getDirectOfferEscrow(positionKey, poolId), directOfferEscrow, "offer escrow unchanged");
        assertEq(harness.getIndexEncumbered(positionKey, poolId), indexEncumbered, "index encumbrance unchanged");
        assertEq(harness.getModuleEncumbered(positionKey, poolId), moduleEncumbered, "module encumbrance unchanged");
    }

    function testProperty_AmmReserveLockOnCreation(
        uint256 principal,
        uint256 locked,
        uint256 lent,
        uint256 directOfferEscrow,
        uint256 indexEncumbered,
        uint256 moduleEncumbered,
        uint256 amount
    ) public {
        principal = bound(principal, 0, type(uint96).max);
        locked = bound(locked, 0, type(uint96).max);
        lent = bound(lent, 0, type(uint96).max);
        directOfferEscrow = bound(directOfferEscrow, 0, type(uint96).max);
        indexEncumbered = bound(indexEncumbered, 0, type(uint96).max);
        moduleEncumbered = bound(moduleEncumbered, 0, type(uint96).max);
        amount = bound(amount, 0, type(uint96).max);

        uint256 poolId = 2;
        bytes32 positionKey =
            keccak256(abi.encodePacked("amm", principal, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered, amount));

        harness.seedPool(poolId, positionKey, principal);
        harness.setEncumbranceState(positionKey, poolId, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered);

        uint256 available = _available(principal, locked, lent, directOfferEscrow, indexEncumbered, moduleEncumbered);

        if (amount == 0) {
            vm.expectRevert(abi.encodeWithSelector(DerivativeError_InvalidAmount.selector, 0));
            harness.lockAmmReserves(positionKey, poolId, amount);
            return;
        }

        if (amount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    DerivativeError_InsufficientPrincipal.selector,
                    available,
                    amount
                )
            );
            harness.lockAmmReserves(positionKey, poolId, amount);
            return;
        }

        harness.lockAmmReserves(positionKey, poolId, amount);
        assertEq(harness.getLent(positionKey, poolId), lent + amount, "lent increases");
        assertEq(harness.getLocked(positionKey, poolId), locked, "locked unchanged");
        assertEq(harness.getDirectOfferEscrow(positionKey, poolId), directOfferEscrow, "offer escrow unchanged");
        assertEq(harness.getIndexEncumbered(positionKey, poolId), indexEncumbered, "index encumbrance unchanged");
        assertEq(harness.getModuleEncumbered(positionKey, poolId), moduleEncumbered, "module encumbrance unchanged");
    }

    function test_lockCollateral_revertsWhenMixedEncumbrancesConsumePrincipal() public {
        uint256 poolId = 3;
        bytes32 positionKey = keccak256("mixed-collateral");
        harness.seedPool(poolId, positionKey, 100 ether);
        harness.setEncumbranceState(positionKey, poolId, 10 ether, 20 ether, 15 ether, 25 ether, 30 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DerivativeError_InsufficientPrincipal.selector,
                0,
                1
            )
        );
        harness.lockCollateral(positionKey, poolId, 1);
    }

    function test_lockAmmReserves_revertsWhenMixedEncumbrancesConsumePrincipal() public {
        uint256 poolId = 4;
        bytes32 positionKey = keccak256("mixed-amm");
        harness.seedPool(poolId, positionKey, 90 ether);
        harness.setEncumbranceState(positionKey, poolId, 10 ether, 10 ether, 20 ether, 25 ether, 25 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DerivativeError_InsufficientPrincipal.selector,
                0,
                1
            )
        );
        harness.lockAmmReserves(positionKey, poolId, 1);
    }

    function _available(
        uint256 principal,
        uint256 locked,
        uint256 lent,
        uint256 directOfferEscrow,
        uint256 indexEncumbered,
        uint256 moduleEncumbered
    ) internal pure returns (uint256) {
        uint256 used = locked + lent + directOfferEscrow + indexEncumbered + moduleEncumbered;
        return principal > used ? principal - used : 0;
    }
}

contract DerivativeHelpersHarness {
    function seedPool(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (!p.initialized) {
            p.underlying = address(0xBEEF);
            p.initialized = true;
        }
        p.userPrincipal[positionKey] = principal;
    }

    function setEncumbranceState(
        bytes32 positionKey,
        uint256 pid,
        uint256 locked,
        uint256 lent,
        uint256 directOfferEscrow,
        uint256 indexEncumbered,
        uint256 moduleEncumbered
    ) external {
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, pid);
        enc.directLocked = locked;
        enc.directLent = lent;
        enc.directOfferEscrow = directOfferEscrow;
        enc.indexEncumbered = indexEncumbered;
        enc.moduleEncumbered = moduleEncumbered;
    }

    function lockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibDerivativeHelpers._lockCollateral(positionKey, poolId, amount);
    }

    function lockAmmReserves(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibDerivativeHelpers._lockAmmReserves(positionKey, poolId, amount);
    }

    function getLocked(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).directLocked;
    }

    function getLent(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).directLent;
    }

    function getDirectOfferEscrow(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).directOfferEscrow;
    }

    function getIndexEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).indexEncumbered;
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).moduleEncumbered;
    }
}

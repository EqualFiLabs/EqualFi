// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {
    LibDerivativeHelpers,
    DerivativeError_InvalidAmount,
    DerivativeError_InsufficientPrincipal
} from "../../src/libraries/LibDerivativeHelpers.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
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
        uint256 amount
    ) public {
        principal = bound(principal, 0, type(uint96).max);
        locked = bound(locked, 0, type(uint96).max);
        lent = bound(lent, 0, type(uint96).max);
        amount = bound(amount, 0, type(uint96).max);

        uint256 poolId = 1;
        bytes32 positionKey = keccak256(abi.encodePacked(principal, locked, lent, amount));

        harness.seedPool(poolId, positionKey, principal);
        harness.setDirectState(positionKey, poolId, locked, lent);

        uint256 available = _available(principal, locked, lent);

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
    }

    function testProperty_AmmReserveLockOnCreation(
        uint256 principal,
        uint256 locked,
        uint256 lent,
        uint256 amount
    ) public {
        principal = bound(principal, 0, type(uint96).max);
        locked = bound(locked, 0, type(uint96).max);
        lent = bound(lent, 0, type(uint96).max);
        amount = bound(amount, 0, type(uint96).max);

        uint256 poolId = 2;
        bytes32 positionKey = keccak256(abi.encodePacked("amm", principal, locked, lent, amount));

        harness.seedPool(poolId, positionKey, principal);
        harness.setDirectState(positionKey, poolId, locked, lent);

        uint256 available = _available(principal, locked, lent);

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
    }

    function _available(uint256 principal, uint256 locked, uint256 lent) internal pure returns (uint256) {
        uint256 used = locked + lent;
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

    function setDirectState(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
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
}

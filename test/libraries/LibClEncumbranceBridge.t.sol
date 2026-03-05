// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClEncumbranceBridge} from "src/libraries/LibClEncumbranceBridge.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {EncumbranceUnderflow} from "src/libraries/Errors.sol";

contract LibClEncumbranceBridgeHarness {
    function lock(
        bytes32 positionKey,
        uint256 poolIdA,
        uint256 amountA,
        uint256 poolIdB,
        uint256 amountB,
        uint256 clPositionId
    ) external {
        LibClEncumbranceBridge.lock(positionKey, poolIdA, amountA, poolIdB, amountB, clPositionId);
    }

    function unlock(
        bytes32 positionKey,
        uint256 poolIdA,
        uint256 amountA,
        uint256 poolIdB,
        uint256 amountB,
        uint256 clPositionId
    ) external {
        LibClEncumbranceBridge.unlock(positionKey, poolIdA, amountA, poolIdB, amountB, clPositionId);
    }

    function getLock(uint256 clPositionId) external view returns (uint256 lockedA, uint256 lockedB) {
        LibClAuctionStorage.EncumbranceLock storage l = LibClAuctionStorage.s().encumbranceLocks[clPositionId];
        return (l.lockedA, l.lockedB);
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function getModuleEncumberedForCl(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumberedForModule(
            positionKey, poolId, LibClEncumbranceBridge.CL_COMMUNITY_AUCTION_MODULE_ID
        );
    }
}

contract LibClEncumbranceBridgeTest is Test {
    LibClEncumbranceBridgeHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("CL_POSITION_KEY");
    uint256 internal constant POOL_ID_A = 11;
    uint256 internal constant POOL_ID_B = 22;
    uint256 internal constant CL_POSITION_ID = 7;

    function setUp() public {
        h = new LibClEncumbranceBridgeHarness();
    }

    function test_lock_updatesEncumbranceAndLockState() public {
        h.lock(POSITION_KEY, POOL_ID_A, 100, POOL_ID_B, 250, CL_POSITION_ID);

        (uint256 lockedA, uint256 lockedB) = h.getLock(CL_POSITION_ID);
        assertEq(lockedA, 100);
        assertEq(lockedB, 250);

        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID_A), 100);
        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID_B), 250);
        assertEq(h.getModuleEncumberedForCl(POSITION_KEY, POOL_ID_A), 100);
        assertEq(h.getModuleEncumberedForCl(POSITION_KEY, POOL_ID_B), 250);
    }

    function test_unlock_updatesEncumbranceAndLockState() public {
        h.lock(POSITION_KEY, POOL_ID_A, 500, POOL_ID_B, 300, CL_POSITION_ID);
        h.unlock(POSITION_KEY, POOL_ID_A, 120, POOL_ID_B, 50, CL_POSITION_ID);

        (uint256 lockedA, uint256 lockedB) = h.getLock(CL_POSITION_ID);
        assertEq(lockedA, 380);
        assertEq(lockedB, 250);

        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID_A), 380);
        assertEq(h.getModuleEncumbered(POSITION_KEY, POOL_ID_B), 250);
        assertEq(h.getModuleEncumberedForCl(POSITION_KEY, POOL_ID_A), 380);
        assertEq(h.getModuleEncumberedForCl(POSITION_KEY, POOL_ID_B), 250);
    }

    function test_unlock_revertsWhenOverLockedAmount() public {
        h.lock(POSITION_KEY, POOL_ID_A, 10, POOL_ID_B, 0, CL_POSITION_ID);

        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 11, 10));
        h.unlock(POSITION_KEY, POOL_ID_A, 11, POOL_ID_B, 0, CL_POSITION_ID);
    }

    function test_moduleId_isDedicatedAndStable() public {
        assertEq(
            LibClEncumbranceBridge.CL_COMMUNITY_AUCTION_MODULE_ID,
            uint256(keccak256("equalis.cl.community.auction.module.v1"))
        );
    }
}

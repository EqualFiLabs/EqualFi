// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ModuleInactive,
    ModuleAumOutOfBounds,
    ModuleIncorrectFee,
    NotModuleOwner,
    EncumbranceUnderflow
} from "../../src/libraries/Errors.sol";
import {LibModuleEncumbrance} from "../../src/libraries/LibModuleEncumbrance.sol";

contract ModuleErrorsHarness {
    function revertModuleInactive(uint256 moduleId) external pure {
        revert ModuleInactive(moduleId);
    }

    function revertModuleAumOutOfBounds(uint16 bps, uint16 minBps, uint16 maxBps) external pure {
        revert ModuleAumOutOfBounds(bps, minBps, maxBps);
    }

    function revertModuleIncorrectFee(uint256 sent, uint256 required) external pure {
        revert ModuleIncorrectFee(sent, required);
    }

    function revertNotModuleOwner(uint256 moduleId, address caller) external pure {
        revert NotModuleOwner(moduleId, caller);
    }

    function triggerModuleUnderflow(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
    }
}

contract ModuleErrorsTest is Test {
    ModuleErrorsHarness internal h;

    bytes32 internal constant POSITION_KEY = keccak256("POSITION");
    uint256 internal constant POOL_ID = 1;
    uint256 internal constant MODULE_ID = 77;

    function setUp() public {
        h = new ModuleErrorsHarness();
    }

    function test_authPath_revertsNotModuleOwner() public {
        vm.expectRevert(abi.encodeWithSelector(NotModuleOwner.selector, MODULE_ID, address(this)));
        h.revertNotModuleOwner(MODULE_ID, address(this));
    }

    function test_feePath_revertsModuleIncorrectFee() public {
        vm.expectRevert(abi.encodeWithSelector(ModuleIncorrectFee.selector, 1 ether, 2 ether));
        h.revertModuleIncorrectFee(1 ether, 2 ether);
    }

    function test_feeBoundsPath_revertsModuleAumOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ModuleAumOutOfBounds.selector, uint16(401), uint16(0), uint16(400)));
        h.revertModuleAumOutOfBounds(401, 0, 400);
    }

    function test_inactivePath_revertsModuleInactive() public {
        vm.expectRevert(abi.encodeWithSelector(ModuleInactive.selector, MODULE_ID));
        h.revertModuleInactive(MODULE_ID);
    }

    function test_underflowPath_revertsEncumbranceUnderflow() public {
        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 1, 0));
        h.triggerModuleUnderflow(POSITION_KEY, POOL_ID, MODULE_ID, 1);
    }
}

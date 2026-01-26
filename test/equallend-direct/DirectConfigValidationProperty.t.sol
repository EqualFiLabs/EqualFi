// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidConfiguration} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Property 1: Configuration Validation Consistency (Requirements 1.2, 10.2)
contract DirectConfigValidationPropertyTest is DirectDiamondTestBase {
    address internal owner = address(0xA11CE);
    address internal timelock = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        harness.setOwner(owner);
        harness.setTimelock(timelock);
    }

    function _validConfig() internal view returns (DirectTypes.DirectConfig memory) {
        return DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 4_500,
            defaultLenderBps: 7_000,
            minInterestDuration: 1 days
        });
    }

    function testProperty_ConfigValidation() public {
        DirectTypes.DirectConfig memory cfg = _validConfig();

        // Owner can set
        vm.prank(owner);
        views.setDirectConfig(cfg);
        DirectTypes.DirectConfig memory stored = views.getDirectConfig();
        assertEq(stored.platformFeeBps, cfg.platformFeeBps);
        assertEq(stored.platformFeeLenderBps, cfg.platformFeeLenderBps);

        // Timelock can set
        cfg.platformFeeBps = 200;
        vm.prank(timelock);
        views.setDirectConfig(cfg);

        DirectTypes.DirectConfig memory badConfig = cfg;
        badConfig.platformFeeBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        views.setDirectConfig(badConfig);

        badConfig = cfg;
        badConfig.platformFeeLenderBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        views.setDirectConfig(badConfig);
    }
}

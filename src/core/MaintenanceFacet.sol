// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibMaintenance} from "../libraries/LibMaintenance.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";

/// @notice Minimal facet exposing pool-level maintenance enforcement hooks.
contract MaintenanceFacet is ReentrancyGuardModifiers {
    event MaintenancePoked(uint256 indexed pid);
    event MaintenanceForcePaid(uint256 indexed pid);

    /// @notice Trigger deterministic maintenance accrual and payout for a pool.
    function pokeMaintenance(uint256 pid) external nonReentrant {
        require(LibAppStorage.s().foundationReceiver != address(0), "Maintenance: receiver not set");
        LibMaintenance.enforce(pid);
        emit MaintenancePoked(pid);
    }

    /// @notice Attempt to pay any outstanding maintenance debt immediately.
    function settleMaintenance(uint256 pid) external nonReentrant {
        require(LibAppStorage.s().foundationReceiver != address(0), "Maintenance: receiver not set");
        LibMaintenance.forcePay(pid);
        emit MaintenanceForcePaid(pid);
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](2);
        selectorsArr[0] = MaintenanceFacet.pokeMaintenance.selector;
        selectorsArr[1] = MaintenanceFacet.settleMaintenance.selector;
    }
}

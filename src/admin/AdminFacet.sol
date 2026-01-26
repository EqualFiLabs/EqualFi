// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";

/// @notice Minimal admin utilities for scaffold (owner/timelock management)
contract AdminFacet {
    event TimelockUpdated(address indexed previous, address indexed current);

    function setTimelock(address newTimelock) external {
        LibAccess.enforceOwner();
        address previous = LibAppStorage.timelockAddress(LibAppStorage.s());
        LibAppStorage.s().timelock = newTimelock;
        emit TimelockUpdated(previous, newTimelock);
    }

    function timelock() external view returns (address) {
        return LibAppStorage.timelockAddress(LibAppStorage.s());
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDiamond} from "./LibDiamond.sol";
import {LibAppStorage} from "./LibAppStorage.sol";

/// @notice Minimal access helpers for owner/timelock gated calls
library LibAccess {
    function enforceOwner() internal view {
        LibDiamond.enforceIsContractOwner();
    }

    function enforceOwnerOrTimelock() internal view {
        address sender = msg.sender;
        if (sender == LibDiamond.diamondStorage().contractOwner) return;
        require(sender == LibAppStorage.timelockAddress(LibAppStorage.s()), "LibAccess: not owner or timelock");
    }

    function isOwnerOrTimelock(address account) internal view returns (bool) {
        if (account == LibDiamond.diamondStorage().contractOwner) return true;
        return account == LibAppStorage.timelockAddress(LibAppStorage.s());
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/// @title ERC6551BeaconProxy
/// @notice Beacon-backed implementation for ERC-6551 registry deployments
/// @dev Deploy once with a beacon address; pass this contract as the registry "implementation".
contract ERC6551BeaconProxy {
    address internal immutable BEACON;

    error BeaconNotContract(address beacon);

    constructor(address beacon) {
        if (beacon.code.length == 0) {
            revert BeaconNotContract(beacon);
        }
        BEACON = beacon;
    }

    function beacon() external view returns (address) {
        return BEACON;
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() internal {
        address implementation = IBeacon(BEACON).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Diamond-wide reentrancy guard stored in a dedicated slot.
library LibReentrancyGuard {
    error ReentrancyGuard_ReentrantCall();

    // keccak256("equallend.reentrancy.guard")
    bytes32 private constant STORAGE_SLOT = 0x8c5ddf4f4cc0c16e2ee35f5e5ae3d5c1d3a1c9fbb0290c3044da811790970d65;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    struct Layout {
        uint256 status;
    }

    function layout() private pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function _enter() internal {
        Layout storage l = layout();
        if (l.status == _ENTERED) revert ReentrancyGuard_ReentrantCall();
        l.status = _ENTERED;
    }

    function _exit() internal {
        layout().status = _NOT_ENTERED;
    }
}

/// @notice Modifier helper that uses the shared guard storage.
abstract contract ReentrancyGuardModifiers {
    modifier nonReentrant() {
        LibReentrancyGuard._enter();
        _;
        LibReentrancyGuard._exit();
    }
}

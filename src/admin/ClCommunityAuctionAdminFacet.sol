// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibClAuctionStorage} from "../libraries/LibClAuctionStorage.sol";
import {ClAuction_InvalidTickSpacing} from "../libraries/ClAuctionErrors.sol";

/// @notice Governance controls for concentrated-liquidity community auctions.
contract ClCommunityAuctionAdminFacet {
    event ClCreationEnabledUpdated(bool enabled);
    event ClSwapFeeCapUpdated(uint24 maxFeePips);
    event ClTickSpacingAllowedUpdated(uint24 tickSpacing, bool allowed);
    event ClSwapPausedUpdated(bool paused);

    function setClCreationEnabled(bool enabled) external {
        LibAccess.enforceOwnerOrTimelock();
        LibClAuctionStorage.s().creationEnabled = enabled;
        emit ClCreationEnabledUpdated(enabled);
    }

    function setClSwapFeeCap(uint24 maxFeePips) external {
        LibAccess.enforceOwnerOrTimelock();
        LibClAuctionStorage.s().swapFeeCap = maxFeePips;
        emit ClSwapFeeCapUpdated(maxFeePips);
    }

    function setClTickSpacingAllowed(uint24 tickSpacing, bool allowed) external {
        LibAccess.enforceOwnerOrTimelock();
        if (tickSpacing == 0) revert ClAuction_InvalidTickSpacing(tickSpacing);
        LibClAuctionStorage.s().allowedTickSpacings[tickSpacing] = allowed;
        emit ClTickSpacingAllowedUpdated(tickSpacing, allowed);
    }

    function setClSwapPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibClAuctionStorage.s().swapPaused = paused;
        emit ClSwapPausedUpdated(paused);
    }
}

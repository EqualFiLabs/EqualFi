// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {InsufficientPoolLiquidity, NativeTransferFailed, UnexpectedMsgValue} from "./Errors.sol";

/// @notice Unified currency helper for native ETH and ERC20 operations.
library LibCurrency {
    using SafeERC20 for IERC20;

    function isNative(address token) internal pure returns (bool) {
        return token == address(0);
    }

    function assertZeroMsgValue() internal view {
        if (msg.value != 0) {
            revert UnexpectedMsgValue(msg.value);
        }
    }

    function assertMsgValue(address token, uint256 amount) internal view {
        if (isNative(token)) {
            if (msg.value != 0 && msg.value != amount) {
                revert UnexpectedMsgValue(msg.value);
            }
            return;
        }
        if (msg.value != 0) {
            revert UnexpectedMsgValue(msg.value);
        }
    }

    function balanceOfSelf(address token) internal view returns (uint256) {
        if (isNative(token)) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }

    function nativeAvailable() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 tracked = LibAppStorage.s().nativeTrackedTotal;
        return balance > tracked ? balance - tracked : 0;
    }

    function pull(address token, address from, uint256 amount) internal returns (uint256 received) {
        if (isNative(token)) {
            if (amount == 0) {
                return 0;
            }
            if (msg.value > 0) {
                if (msg.value != amount) {
                    revert UnexpectedMsgValue(msg.value);
                }
                LibAppStorage.s().nativeTrackedTotal += amount;
                return amount;
            }
            uint256 available = nativeAvailable();
            if (amount > available) {
                revert InsufficientPoolLiquidity(amount, available);
            }
            LibAppStorage.s().nativeTrackedTotal += amount;
            return amount;
        }

        if (amount == 0) {
            return 0;
        }
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        received = balanceAfter - balanceBefore;
    }

    function transfer(address token, address to, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        if (isNative(token)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) {
                revert NativeTransferFailed(to, amount);
            }
            return;
        }
        IERC20(token).safeTransfer(to, amount);
    }
}

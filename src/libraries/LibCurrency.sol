// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {InsufficientPoolLiquidity, NativeTransferFailed, UnexpectedMsgValue} from "./Errors.sol";

/// @notice Unified currency helper for native ETH and ERC20 operations.
library LibCurrency {
    using SafeERC20 for IERC20;

    error LibCurrency_InvalidMax(uint256 maxAmount, uint256 minAmount);
    error LibCurrency_InsufficientReceived(uint256 received, uint256 required);
    error LibCurrency_DecimalsQueryFailed(address token);

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

    function decimals(address token) internal view returns (uint8) {
        if (isNative(token)) {
            return 18;
        }
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    function decimalsOrRevert(address token) internal view returns (uint8) {
        if (isNative(token)) {
            return 18;
        }
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            revert LibCurrency_DecimalsQueryFailed(token);
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

    function pullAtLeast(
        address token,
        address from,
        uint256 minAmount,
        uint256 maxAmount
    ) internal returns (uint256 received) {
        if (maxAmount < minAmount) {
            revert LibCurrency_InvalidMax(maxAmount, minAmount);
        }
        if (minAmount == 0 && maxAmount == 0) {
            return 0;
        }
        if (isNative(token)) {
            if (msg.value != maxAmount) {
                revert UnexpectedMsgValue(msg.value);
            }
            LibAppStorage.s().nativeTrackedTotal += maxAmount;
            received = maxAmount;
        } else {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(from, address(this), maxAmount);
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            received = balanceAfter - balanceBefore;
        }
        if (received < minAmount) {
            revert LibCurrency_InsufficientReceived(received, minAmount);
        }
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

    function transferWithMin(
        address token,
        address to,
        uint256 amount,
        uint256 minReceived
    ) internal returns (uint256 received) {
        if (amount == 0) {
            return 0;
        }
        if (isNative(token)) {
            uint256 balanceBefore = to.balance;
            (bool success,) = to.call{value: amount}("");
            if (!success) {
                revert NativeTransferFailed(to, amount);
            }
            received = to.balance - balanceBefore;
        } else {
            uint256 balanceBefore = IERC20(token).balanceOf(to);
            IERC20(token).safeTransfer(to, amount);
            uint256 balanceAfter = IERC20(token).balanceOf(to);
            received = balanceAfter - balanceBefore;
        }
        if (received < minReceived) {
            revert LibCurrency_InsufficientReceived(received, minReceived);
        }
    }
}

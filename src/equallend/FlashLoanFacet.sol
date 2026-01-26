// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeTreasury} from "../libraries/LibFeeTreasury.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";

interface IFlashLoanReceiver {
    function onFlashLoan(address initiator, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32);
}

/// @notice Flash loans with ETH flat fee routing (no fee index impact)
contract FlashLoanFacet is ReentrancyGuardModifiers {
    event FlashLoan(uint256 indexed pid, address indexed receiver, uint256 amount, uint256 fee, uint16 feeBps);

    bytes32 internal constant FLASH_CALLBACK_SUCCESS = keccak256("IFlashLoanReceiver.onFlashLoan");

    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = s().pools[pid];
        require(p.initialized, "Flash: pool not initialized");
        return p;
    }


    function flashLoan(uint256 pid, address receiver, uint256 amount, bytes calldata data) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        Types.PoolData storage p = _pool(pid);
        require(amount > 0, "Flash: amount=0");
        require(amount <= p.trackedBalance, "Flash: insufficient pool liquidity");
        uint16 feeBps = p.poolConfig.flashLoanFeeBps;
        require(feeBps > 0, "Flash: fee not set");
        uint256 fee = (amount * feeBps) / 10_000;

        // enforce anti-split by simple aggregate per block if enabled
        LibAppStorage.FlashAgg storage agg = s().flashAgg[receiver][pid];
        if (p.poolConfig.flashLoanAntiSplit) {
            require(agg.blockNumber == 0 || agg.blockNumber < block.number, "Flash: split block");
            agg.blockNumber = block.number;
            agg.amount = amount;
        }

        uint256 balBefore = LibCurrency.balanceOfSelf(p.underlying);
        require(balBefore >= amount, "Flash: insufficient contract balance");
        LibCurrency.transfer(p.underlying, receiver, amount);

        require(
            IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, p.underlying, amount, data) == FLASH_CALLBACK_SUCCESS,
            "Flash: callback"
        );

        if (LibCurrency.isNative(p.underlying)) {
            uint256 balAfter = LibCurrency.balanceOfSelf(p.underlying);
            require(balAfter >= balBefore + fee, "Flash: not repaid");
        } else {
            // Pull repayment explicitly from the receiver to prevent cross-pool balance spoofing
            LibCurrency.pull(p.underlying, receiver, amount + fee);
            uint256 balAfter = LibCurrency.balanceOfSelf(p.underlying);
            require(balAfter >= balBefore + fee, "Flash: not repaid");
        }

        if (fee > 0) {
            // Track the newly accrued fee in pool balance before splitting
            p.trackedBalance += fee;
            if (LibCurrency.isNative(p.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += fee;
            }
            LibFeeTreasury.accrueWithTreasury(p, pid, fee, bytes32("flashLoan"));
        }

        emit FlashLoan(pid, receiver, amount, fee, feeBps);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AtomicTypes} from "../libraries/AtomicTypes.sol";
import {LibAtomicStorage} from "../libraries/LibAtomicStorage.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import {InsufficientPrincipal, Unauthorized} from "../libraries/Errors.sol";
import {IMailbox} from "../interfaces/IMailbox.sol";

error SettlementEscrow_InvalidParam();
error SettlementEscrow_ReservationInactive(bytes32 reservationId);
error SettlementEscrow_RefundWindowActive(bytes32 reservationId);

/// @notice Escrow lifecycle for Atomic Desk reservations.
contract SettlementEscrowFacet is ReentrancyGuardModifiers {
    uint16 internal constant MAKER_FEE_BPS = 7000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    bytes32 internal constant ATOMIC_SWAP_FEE_SOURCE = keccak256("ATOMIC_SWAP_FEE");

    event ReservationSettled(bytes32 indexed reservationId, bytes32 tau);
    event ReservationRefunded(bytes32 indexed reservationId, bytes32 evidence);
    event HashlockSet(bytes32 indexed reservationId, bytes32 hashlock);
    event TrancheLiquidityRestored(bytes32 indexed trancheId, uint256 amount, uint256 remainingLiquidity);

    event CommitteeUpdated(address indexed member, bool allowed);
    event GovernorTransferred(address indexed newGovernor);
    event MailboxConfigured(address indexed mailbox);
    event AtomicDeskConfigured(address indexed atomicDesk);
    event RefundSafetyWindowUpdated(uint64 newWindow);

    modifier onlyGovernor() {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        address gov = st.governor;
        if (gov == address(0)) {
            LibAccess.enforceOwnerOrTimelock();
        } else if (msg.sender != gov) {
            revert Unauthorized();
        }
        _;
    }

    function setHashlock(bytes32 reservationId, bytes32 hashlock) external {
        AtomicTypes.Reservation storage r = LibAtomicStorage.atomicStorage().reservations[reservationId];
        if (r.status != AtomicTypes.ReservationStatus.Active) {
            revert SettlementEscrow_ReservationInactive(reservationId);
        }
        if (hashlock == bytes32(0)) revert SettlementEscrow_InvalidParam();
        if (r.hashlock != bytes32(0)) revert SettlementEscrow_InvalidParam();
        if (msg.sender != r.desk) revert Unauthorized();

        r.hashlock = hashlock;
        emit HashlockSet(reservationId, hashlock);
    }

    function settle(bytes32 reservationId, bytes32 tau) external nonReentrant {
        AtomicTypes.Reservation storage r = LibAtomicStorage.atomicStorage().reservations[reservationId];
        if (r.status != AtomicTypes.ReservationStatus.Active) {
            revert SettlementEscrow_ReservationInactive(reservationId);
        }
        if (r.hashlock == bytes32(0)) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (msg.sender != r.desk && !st.committee[msg.sender]) revert Unauthorized();
        if (keccak256(abi.encodePacked(tau)) != r.hashlock) revert SettlementEscrow_InvalidParam();

        r.status = AtomicTypes.ReservationStatus.Settled;
        uint256 amount = r.amount;
        r.amount = 0;

        uint256 basePoolId = r.baseIsA ? r.poolIdA : r.poolIdB;
        LibDerivativeHelpers._unlockCollateral(r.positionKey, basePoolId, amount);
        LibFeeIndex.settle(basePoolId, r.positionKey);

        Types.PoolData storage pool = LibDirectHelpers._pool(basePoolId);
        uint256 principal = pool.userPrincipal[r.positionKey];
        if (principal < amount) revert InsufficientPrincipal(amount, principal);
        uint256 payout = amount;
        uint256 protocolFee;
        uint256 makerShare;
        uint256 toTreasury;

        if (r.feePayer == AtomicTypes.FeePayer.Taker && r.feeBps > 0) {
            uint256 feeAmount = (amount * r.feeBps) / BPS_DENOMINATOR;
            if (feeAmount > amount) feeAmount = amount;
            makerShare = (feeAmount * MAKER_FEE_BPS) / BPS_DENOMINATOR;
            protocolFee = feeAmount - makerShare;
            payout = amount - feeAmount;
            if (protocolFee > 0) {
                (toTreasury,,) = LibFeeRouter.previewSplit(protocolFee);
            }
        }

        uint256 requiredTracked = payout + toTreasury;
        if (pool.trackedBalance < requiredTracked) {
            revert InsufficientPrincipal(requiredTracked, pool.trackedBalance);
        }

        pool.userPrincipal[r.positionKey] = principal - amount + makerShare;
        pool.totalDeposits =
            pool.totalDeposits >= amount ? pool.totalDeposits - amount + makerShare : makerShare;
        pool.trackedBalance -= payout;
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= payout;
        }

        if (protocolFee > 0) {
            LibFeeRouter.routeSamePool(basePoolId, protocolFee, ATOMIC_SWAP_FEE_SOURCE, true, 0);
        }

        LibCurrency.transfer(r.asset, r.taker, payout);
        _revokeMailboxSlot(reservationId, st.mailbox);

        emit ReservationSettled(reservationId, tau);
    }

    function refund(bytes32 reservationId, bytes32 noSpendEvidence) external nonReentrant {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (!st.committee[msg.sender]) revert Unauthorized();
        if (noSpendEvidence == bytes32(0)) revert SettlementEscrow_InvalidParam();

        AtomicTypes.Reservation storage r = st.reservations[reservationId];
        if (r.status != AtomicTypes.ReservationStatus.Active) {
            revert SettlementEscrow_ReservationInactive(reservationId);
        }
        if (block.timestamp < uint256(r.createdAt) + st.refundSafetyWindow) {
            revert SettlementEscrow_RefundWindowActive(reservationId);
        }

        r.status = AtomicTypes.ReservationStatus.Refunded;
        uint256 amount = r.amount;
        r.amount = 0;

        uint256 basePoolId = r.baseIsA ? r.poolIdA : r.poolIdB;
        LibDerivativeHelpers._unlockCollateral(r.positionKey, basePoolId, amount);
        _restoreTrancheLiquidity(reservationId, amount);
        _revokeMailboxSlot(reservationId, st.mailbox);

        emit ReservationRefunded(reservationId, noSpendEvidence);
    }

    function getReservation(bytes32 reservationId)
        external
        view
        returns (AtomicTypes.Reservation memory)
    {
        AtomicTypes.Reservation storage r = LibAtomicStorage.atomicStorage().reservations[reservationId];
        if (r.reservationId == bytes32(0)) {
            revert SettlementEscrow_ReservationInactive(reservationId);
        }
        return r;
    }

    function setCommittee(address member, bool allowed) external onlyGovernor {
        if (member == address(0)) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.atomicStorage().committee[member] = allowed;
        emit CommitteeUpdated(member, allowed);
    }

    function configureMailbox(address mailbox_) external onlyGovernor {
        if (mailbox_ == address(0)) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.atomicStorage().mailbox = mailbox_;
        emit MailboxConfigured(mailbox_);
    }

    function configureAtomicDesk(address atomicDesk_) external onlyGovernor {
        if (atomicDesk_ == address(0)) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.atomicStorage().atomicDesk = atomicDesk_;
        emit AtomicDeskConfigured(atomicDesk_);
    }

    function transferGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.atomicStorage().governor = newGovernor;
        emit GovernorTransferred(newGovernor);
    }

    function setRefundSafetyWindow(uint64 newWindow) external onlyGovernor {
        if (newWindow == 0) revert SettlementEscrow_InvalidParam();
        LibAtomicStorage.atomicStorage().refundSafetyWindow = newWindow;
        emit RefundSafetyWindowUpdated(newWindow);
    }

    function refundSafetyWindow() external view returns (uint64) {
        return LibAtomicStorage.atomicStorage().refundSafetyWindow;
    }

    function committee(address member) external view returns (bool) {
        return LibAtomicStorage.atomicStorage().committee[member];
    }

    function governor() external view returns (address) {
        return LibAtomicStorage.atomicStorage().governor;
    }

    function mailbox() external view returns (address) {
        return LibAtomicStorage.atomicStorage().mailbox;
    }

    function atomicDesk() external view returns (address) {
        address configured = LibAtomicStorage.atomicStorage().atomicDesk;
        return configured == address(0) ? address(this) : configured;
    }

    function _revokeMailboxSlot(bytes32 reservationId, address mailbox_) internal {
        if (mailbox_ == address(0)) return;
        if (IMailbox(mailbox_).isSlotAuthorized(reservationId)) {
            IMailbox(mailbox_).revokeReservation(reservationId);
        }
    }

    function _restoreTrancheLiquidity(bytes32 reservationId, uint256 amount) internal {
        if (amount == 0) return;
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        bytes32 trancheId = st.reservationTranche[reservationId];
        if (trancheId == bytes32(0)) return;
        AtomicTypes.Tranche storage makerTranche = st.tranches[trancheId];
        if (makerTranche.trancheId != bytes32(0)) {
            uint256 newRemaining = makerTranche.remainingLiquidity + amount;
            if (newRemaining > makerTranche.totalLiquidity) {
                newRemaining = makerTranche.totalLiquidity;
            }
            makerTranche.remainingLiquidity = newRemaining;
            if (!makerTranche.active && newRemaining > 0) {
                if (makerTranche.expiry == 0 || makerTranche.expiry > block.timestamp) {
                    makerTranche.active = true;
                }
            }
            emit TrancheLiquidityRestored(trancheId, amount, newRemaining);
            return;
        }

        AtomicTypes.TakerTranche storage takerTranche = st.takerTranches[trancheId];
        if (takerTranche.trancheId == bytes32(0)) return;
        uint256 newRemaining = takerTranche.remainingLiquidity + amount;
        if (newRemaining > takerTranche.totalLiquidity) {
            newRemaining = takerTranche.totalLiquidity;
        }
        takerTranche.remainingLiquidity = newRemaining;
        if (!takerTranche.active && newRemaining > 0) {
            if (takerTranche.expiry == 0 || takerTranche.expiry > block.timestamp) {
                takerTranche.active = true;
            }
        }
        emit TrancheLiquidityRestored(trancheId, amount, newRemaining);
    }
}

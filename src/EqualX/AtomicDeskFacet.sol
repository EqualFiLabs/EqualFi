// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AtomicTypes} from "../libraries/AtomicTypes.sol";
import {LibAtomicStorage} from "../libraries/LibAtomicStorage.sol";
import {LibDerivativeHelpers} from "../libraries/LibDerivativeHelpers.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import {InvalidTreasuryAddress, PoolMembershipRequired} from "../libraries/Errors.sol";
import {IMailbox} from "../interfaces/IMailbox.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

error AtomicDesk_InvalidDesk();
error AtomicDesk_InvalidAmount();
error AtomicDesk_InvalidExpiry();
error AtomicDesk_InvalidSettlementDigest();
error AtomicDesk_InvalidTaker();
error AtomicDesk_ReservationNotActive(bytes32 reservationId);
error AtomicDesk_HashlockAlreadySet(bytes32 reservationId);
error AtomicDesk_IncorrectAsset(address asset);
error AtomicDesk_Paused();
error AtomicDesk_InvalidPool(uint256 poolId);
error AtomicDesk_InvalidTranche();
error AtomicDesk_TrancheInactive(bytes32 trancheId);
error AtomicDesk_TrancheExpired(bytes32 trancheId);
error AtomicDesk_TrancheLiquidityExceeded(uint256 requested, uint256 available);
error AtomicDesk_InvalidPrice();
error AtomicDesk_InvalidFeeBps(uint16 feeBps);
error AtomicDesk_InvalidFeePayer();
error AtomicDesk_InvalidPostingFee(uint256 expected, uint256 received);

/// @notice AtomicDesk entrypoint using Position NFT collateral.
contract AtomicDeskFacet is ReentrancyGuardModifiers {
    uint64 public constant MIN_EXPIRY_WINDOW = 5 minutes;
    uint16 internal constant MAKER_FEE_BPS = 7000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    bytes32 internal constant ATOMIC_SWAP_FEE_SOURCE = keccak256("ATOMIC_SWAP_FEE");

    event ReservationCreated(
        bytes32 indexed reservationId,
        address indexed taker,
        address indexed desk,
        uint256 amount,
        uint256 counter
    );

    event AtomicDeskReservationCreated(
        bytes32 indexed reservationId,
        bytes32 indexed deskId,
        address indexed taker,
        address asset,
        uint256 amount,
        bytes32 settlementDigest,
        uint64 expiry,
        uint64 createdAt
    );

    event HashlockSet(bytes32 indexed reservationId, bytes32 hashlock);

    event TrancheOpened(
        bytes32 indexed trancheId,
        bytes32 indexed deskId,
        address indexed maker,
        address asset,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 totalLiquidity,
        uint256 minFill,
        uint16 feeBps,
        uint8 feePayer,
        uint64 expiry
    );

    event TrancheStatusUpdated(bytes32 indexed trancheId, bool active);

    event TrancheReserved(
        bytes32 indexed trancheId,
        bytes32 indexed reservationId,
        address indexed taker,
        uint256 amount,
        uint256 remainingLiquidity
    );

    event TakerTrancheOpened(
        bytes32 indexed trancheId,
        bytes32 indexed deskId,
        address indexed taker,
        address asset,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 totalLiquidity,
        uint256 minFill,
        uint16 feeBps,
        uint8 feePayer,
        uint64 expiry,
        uint256 postingFee
    );

    event TakerTrancheStatusUpdated(bytes32 indexed trancheId, bool active);

    event TakerTrancheReserved(
        bytes32 indexed trancheId,
        bytes32 indexed reservationId,
        address indexed maker,
        uint256 amount,
        uint256 remainingLiquidity
    );

    event TakerTranchePostingFeeUpdated(uint256 feeWei);

    event DeskRegistered(
        bytes32 indexed deskId,
        bytes32 indexed positionKey,
        uint256 indexed positionId,
        bool baseIsA
    );
    event DeskStatusUpdated(bytes32 indexed deskId, bool active);
    event AtomicPausedUpdated(bool paused);

    function setAtomicPaused(bool paused) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAtomicStorage.atomicStorage().atomicPaused = paused;
        emit AtomicPausedUpdated(paused);
    }

    function registerDesk(
        uint256 positionId,
        uint256 poolIdA,
        uint256 poolIdB,
        bool baseIsA
    ) external returns (bytes32 deskId) {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(positionId);

        (poolIdA, poolIdB, baseIsA) = _canonicalPools(poolIdA, poolIdB, baseIsA);
        Types.PoolData storage poolA = LibDirectHelpers._pool(poolIdA);
        Types.PoolData storage poolB = LibDirectHelpers._pool(poolIdB);

        if (!LibPoolMembership.isMember(positionKey, poolIdA)) {
            revert PoolMembershipRequired(positionKey, poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, poolIdB)) {
            revert PoolMembershipRequired(positionKey, poolIdB);
        }

        deskId = keccak256(abi.encodePacked(positionKey, poolIdA, poolIdB));
        AtomicTypes.DeskConfig storage cfg = st.desks[deskId];
        cfg.positionKey = positionKey;
        cfg.positionId = positionId;
        cfg.poolIdA = poolIdA;
        cfg.poolIdB = poolIdB;
        cfg.tokenA = poolA.underlying;
        cfg.tokenB = poolB.underlying;
        cfg.baseIsA = baseIsA;
        cfg.active = true;
        cfg.maker = msg.sender;

        emit DeskRegistered(deskId, positionKey, positionId, baseIsA);
        emit DeskStatusUpdated(deskId, true);
    }

    function setDeskStatus(bytes32 deskId, bool active) external {
        AtomicTypes.DeskConfig storage cfg = LibAtomicStorage.atomicStorage().desks[deskId];
        if (cfg.maker == address(0) || cfg.maker != msg.sender) revert AtomicDesk_InvalidDesk();
        cfg.active = active;
        emit DeskStatusUpdated(deskId, active);
    }

    function openTranche(
        bytes32 deskId,
        uint256 totalLiquidity,
        uint256 minFill,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint16 feeBps,
        AtomicTypes.FeePayer feePayer,
        uint64 expiry
    ) external returns (bytes32 trancheId) {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        AtomicTypes.DeskConfig storage cfg = st.desks[deskId];
        if (!cfg.active || cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        if (cfg.maker != msg.sender) revert AtomicDesk_InvalidDesk();
        if (priceNumerator == 0 || priceDenominator == 0) revert AtomicDesk_InvalidPrice();
        if (totalLiquidity == 0 || minFill == 0 || minFill > totalLiquidity) {
            revert AtomicDesk_InvalidAmount();
        }
        _validateFeeConfig(feeBps, feePayer);
        if (expiry != 0 && expiry <= block.timestamp) revert AtomicDesk_InvalidExpiry();

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(cfg.positionId);
        if (positionKey != cfg.positionKey) revert AtomicDesk_InvalidDesk();

        uint256 basePoolId = cfg.baseIsA ? cfg.poolIdA : cfg.poolIdB;
        uint256 available = _availablePrincipal(positionKey, basePoolId);
        if (totalLiquidity > available) {
            revert AtomicDesk_TrancheLiquidityExceeded(totalLiquidity, available);
        }

        uint256 counter = ++st.trancheCounter;
        trancheId = keccak256(abi.encodePacked(block.timestamp, positionKey, deskId, counter));

        AtomicTypes.Tranche storage tranche = st.tranches[trancheId];
        tranche.trancheId = trancheId;
        tranche.deskId = deskId;
        tranche.positionKey = positionKey;
        tranche.positionId = cfg.positionId;
        tranche.maker = cfg.maker;
        tranche.asset = cfg.baseIsA ? cfg.tokenA : cfg.tokenB;
        tranche.priceNumerator = priceNumerator;
        tranche.priceDenominator = priceDenominator;
        tranche.totalLiquidity = totalLiquidity;
        tranche.remainingLiquidity = totalLiquidity;
        tranche.minFill = minFill;
        tranche.feeBps = feeBps;
        tranche.feePayer = feePayer;
        tranche.expiry = expiry;
        tranche.createdAt = uint64(block.timestamp);
        tranche.active = true;

        emit TrancheOpened(
            trancheId,
            deskId,
            cfg.maker,
            tranche.asset,
            priceNumerator,
            priceDenominator,
            totalLiquidity,
            minFill,
            feeBps,
            uint8(feePayer),
            expiry
        );
        emit TrancheStatusUpdated(trancheId, true);
    }

    function setTrancheStatus(bytes32 trancheId, bool active) external {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        AtomicTypes.Tranche storage tranche = st.tranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        if (tranche.maker != msg.sender) revert AtomicDesk_InvalidDesk();
        AtomicTypes.DeskConfig storage cfg = st.desks[tranche.deskId];
        if (cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        _requireDeskOwner(cfg);
        tranche.active = active;
        emit TrancheStatusUpdated(trancheId, active);
    }

    function getTranche(bytes32 trancheId) external view returns (AtomicTypes.Tranche memory) {
        AtomicTypes.Tranche storage tranche = LibAtomicStorage.atomicStorage().tranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        return tranche;
    }

    function getReservationTranche(bytes32 reservationId) external view returns (bytes32 trancheId) {
        trancheId = LibAtomicStorage.atomicStorage().reservationTranche[reservationId];
    }

    function openTakerTranche(
        bytes32 deskId,
        uint256 totalLiquidity,
        uint256 minFill,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint16 feeBps,
        AtomicTypes.FeePayer feePayer,
        uint64 expiry
    ) external payable nonReentrant returns (bytes32 trancheId) {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        AtomicTypes.DeskConfig storage cfg = st.desks[deskId];
        if (!cfg.active || cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        if (priceNumerator == 0 || priceDenominator == 0) revert AtomicDesk_InvalidPrice();
        if (totalLiquidity == 0 || minFill == 0 || minFill > totalLiquidity) {
            revert AtomicDesk_InvalidAmount();
        }
        _validateFeeConfig(feeBps, feePayer);
        if (expiry != 0 && expiry <= block.timestamp) revert AtomicDesk_InvalidExpiry();
        if (msg.sender == cfg.maker) revert AtomicDesk_InvalidTaker();

        bytes32 positionKey = cfg.positionKey;
        _requireDeskOwner(cfg);

        address asset = cfg.baseIsA ? cfg.tokenA : cfg.tokenB;
        uint256 postingFee = st.takerTranchePostingFee;
        _collectTakerTranchePostingFee(postingFee);

        uint256 counter = ++st.takerTrancheCounter;
        trancheId = keccak256(abi.encodePacked(block.timestamp, positionKey, deskId, msg.sender, counter));

        AtomicTypes.TakerTranche storage tranche = st.takerTranches[trancheId];
        tranche.trancheId = trancheId;
        tranche.deskId = deskId;
        tranche.positionKey = positionKey;
        tranche.positionId = cfg.positionId;
        tranche.taker = msg.sender;
        tranche.asset = asset;
        tranche.priceNumerator = priceNumerator;
        tranche.priceDenominator = priceDenominator;
        tranche.totalLiquidity = totalLiquidity;
        tranche.remainingLiquidity = totalLiquidity;
        tranche.minFill = minFill;
        tranche.feeBps = feeBps;
        tranche.feePayer = feePayer;
        tranche.expiry = expiry;
        tranche.createdAt = uint64(block.timestamp);
        tranche.active = true;

        emit TakerTrancheOpened(
            trancheId,
            deskId,
            msg.sender,
            asset,
            priceNumerator,
            priceDenominator,
            totalLiquidity,
            minFill,
            feeBps,
            uint8(feePayer),
            expiry,
            postingFee
        );
        emit TakerTrancheStatusUpdated(trancheId, true);
    }

    function setTakerTranchePostingFee(uint256 feeWei) external {
        LibAccess.enforceOwnerOrTimelock();
        LibAtomicStorage.atomicStorage().takerTranchePostingFee = feeWei;
        emit TakerTranchePostingFeeUpdated(feeWei);
    }

    function setTakerTrancheStatus(bytes32 trancheId, bool active) external {
        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        AtomicTypes.TakerTranche storage tranche = st.takerTranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        if (tranche.taker != msg.sender) revert AtomicDesk_InvalidTaker();
        tranche.active = active;
        emit TakerTrancheStatusUpdated(trancheId, active);
    }

    function getTakerTranche(bytes32 trancheId) external view returns (AtomicTypes.TakerTranche memory) {
        AtomicTypes.TakerTranche storage tranche = LibAtomicStorage.atomicStorage().takerTranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        return tranche;
    }

    function reserveFromTakerTranche(
        bytes32 trancheId,
        uint256 amount,
        bytes32 settlementDigest,
        uint64 expiry
    ) external payable nonReentrant returns (bytes32 reservationId) {
        LibCurrency.assertZeroMsgValue();

        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        AtomicTypes.TakerTranche storage tranche = st.takerTranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        if (!tranche.active) revert AtomicDesk_TrancheInactive(trancheId);
        if (tranche.expiry != 0 && tranche.expiry <= block.timestamp) {
            revert AtomicDesk_TrancheExpired(trancheId);
        }
        if (amount == 0 || amount < tranche.minFill) revert AtomicDesk_InvalidAmount();
        if (amount > tranche.remainingLiquidity) {
            revert AtomicDesk_TrancheLiquidityExceeded(amount, tranche.remainingLiquidity);
        }
        if (settlementDigest == bytes32(0)) revert AtomicDesk_InvalidSettlementDigest();

        AtomicTypes.DeskConfig storage cfg = st.desks[tranche.deskId];
        if (!cfg.active || cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        if (msg.sender != cfg.maker) revert AtomicDesk_InvalidDesk();
        if (tranche.positionKey != cfg.positionKey || tranche.positionId != cfg.positionId) {
            revert AtomicDesk_InvalidDesk();
        }
        _requireDeskOwner(cfg);

        uint256 nowTs = block.timestamp;
        if (expiry <= nowTs) revert AtomicDesk_InvalidExpiry();
        uint256 minExpiry = nowTs + MIN_EXPIRY_WINDOW;
        if (expiry < minExpiry) revert AtomicDesk_InvalidExpiry();
        uint256 maxExpiry = nowTs + st.refundSafetyWindow;
        if (st.refundSafetyWindow == 0 || expiry > maxExpiry) revert AtomicDesk_InvalidExpiry();
        if (tranche.expiry != 0 && expiry > tranche.expiry) revert AtomicDesk_InvalidExpiry();

        address expectedAsset = cfg.baseIsA ? cfg.tokenA : cfg.tokenB;
        if (expectedAsset != tranche.asset) revert AtomicDesk_InvalidDesk();

        LibFeeIndex.settle(cfg.poolIdA, cfg.positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdA, cfg.positionKey);
        LibFeeIndex.settle(cfg.poolIdB, cfg.positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdB, cfg.positionKey);

        uint256 basePoolId = cfg.baseIsA ? cfg.poolIdA : cfg.poolIdB;
        if (tranche.feePayer == AtomicTypes.FeePayer.Maker) {
            _applyMakerFee(basePoolId, cfg.positionKey, amount, tranche.feeBps);
        }
        LibDerivativeHelpers._lockCollateral(cfg.positionKey, basePoolId, amount);

        tranche.remainingLiquidity -= amount;
        if (tranche.remainingLiquidity == 0) {
            tranche.active = false;
            emit TakerTrancheStatusUpdated(trancheId, false);
        }

        uint256 counter = ++st.reservationCounter;
        reservationId = keccak256(abi.encodePacked(block.timestamp, cfg.positionKey, counter));

        AtomicTypes.Reservation storage r = st.reservations[reservationId];
        r.reservationId = reservationId;
        r.deskId = tranche.deskId;
        r.positionKey = cfg.positionKey;
        r.positionId = cfg.positionId;
        r.desk = cfg.maker;
        r.taker = tranche.taker;
        r.poolIdA = cfg.poolIdA;
        r.poolIdB = cfg.poolIdB;
        r.tokenA = cfg.tokenA;
        r.tokenB = cfg.tokenB;
        r.baseIsA = cfg.baseIsA;
        r.asset = expectedAsset;
        r.amount = amount;
        r.settlementDigest = settlementDigest;
        r.hashlock = bytes32(0);
        r.counter = counter;
        r.expiry = expiry;
        r.createdAt = uint64(block.timestamp);
        r.feeBps = tranche.feeBps;
        r.feePayer = tranche.feePayer;
        r.status = AtomicTypes.ReservationStatus.Active;

        st.reservationTranche[reservationId] = trancheId;

        if (st.mailbox != address(0)) {
            IMailbox(st.mailbox).authorizeReservation(reservationId);
        }

        emit ReservationCreated(reservationId, tranche.taker, cfg.maker, amount, counter);
        emit AtomicDeskReservationCreated(
            reservationId,
            tranche.deskId,
            tranche.taker,
            expectedAsset,
            amount,
            settlementDigest,
            expiry,
            uint64(block.timestamp)
        );
        emit TakerTrancheReserved(trancheId, reservationId, msg.sender, amount, tranche.remainingLiquidity);
    }

    function reserveFromTranche(
        bytes32 trancheId,
        uint256 amount,
        bytes32 settlementDigest,
        uint64 expiry
    ) external payable nonReentrant returns (bytes32 reservationId) {
        LibCurrency.assertZeroMsgValue();

        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        AtomicTypes.Tranche storage tranche = st.tranches[trancheId];
        if (tranche.trancheId == bytes32(0)) revert AtomicDesk_InvalidTranche();
        if (!tranche.active) revert AtomicDesk_TrancheInactive(trancheId);
        if (tranche.expiry != 0 && tranche.expiry <= block.timestamp) {
            revert AtomicDesk_TrancheExpired(trancheId);
        }
        if (amount == 0 || amount < tranche.minFill) revert AtomicDesk_InvalidAmount();
        if (amount > tranche.remainingLiquidity) {
            revert AtomicDesk_TrancheLiquidityExceeded(amount, tranche.remainingLiquidity);
        }
        if (settlementDigest == bytes32(0)) revert AtomicDesk_InvalidSettlementDigest();

        AtomicTypes.DeskConfig storage cfg = st.desks[tranche.deskId];
        if (!cfg.active || cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        if (msg.sender == cfg.maker) revert AtomicDesk_InvalidTaker();
        if (tranche.positionKey != cfg.positionKey || tranche.positionId != cfg.positionId) {
            revert AtomicDesk_InvalidDesk();
        }
        _requireDeskOwner(cfg);
        if (!LibPoolMembership.isMember(cfg.positionKey, cfg.poolIdA)) {
            revert PoolMembershipRequired(cfg.positionKey, cfg.poolIdA);
        }
        if (!LibPoolMembership.isMember(cfg.positionKey, cfg.poolIdB)) {
            revert PoolMembershipRequired(cfg.positionKey, cfg.poolIdB);
        }

        uint256 nowTs = block.timestamp;
        if (expiry <= nowTs) revert AtomicDesk_InvalidExpiry();
        uint256 minExpiry = nowTs + MIN_EXPIRY_WINDOW;
        if (expiry < minExpiry) revert AtomicDesk_InvalidExpiry();
        uint256 maxExpiry = nowTs + st.refundSafetyWindow;
        if (st.refundSafetyWindow == 0 || expiry > maxExpiry) revert AtomicDesk_InvalidExpiry();
        if (tranche.expiry != 0 && expiry > tranche.expiry) revert AtomicDesk_InvalidExpiry();

        address expectedAsset = cfg.baseIsA ? cfg.tokenA : cfg.tokenB;
        if (expectedAsset != tranche.asset) revert AtomicDesk_InvalidDesk();

        LibFeeIndex.settle(cfg.poolIdA, cfg.positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdA, cfg.positionKey);
        LibFeeIndex.settle(cfg.poolIdB, cfg.positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdB, cfg.positionKey);

        uint256 basePoolId = cfg.baseIsA ? cfg.poolIdA : cfg.poolIdB;
        if (tranche.feePayer == AtomicTypes.FeePayer.Maker) {
            _applyMakerFee(basePoolId, cfg.positionKey, amount, tranche.feeBps);
        }
        LibDerivativeHelpers._lockCollateral(cfg.positionKey, basePoolId, amount);

        tranche.remainingLiquidity -= amount;
        if (tranche.remainingLiquidity == 0) {
            tranche.active = false;
            emit TrancheStatusUpdated(trancheId, false);
        }

        uint256 counter = ++st.reservationCounter;
        reservationId = keccak256(abi.encodePacked(block.timestamp, cfg.positionKey, counter));

        AtomicTypes.Reservation storage r = st.reservations[reservationId];
        r.reservationId = reservationId;
        r.deskId = tranche.deskId;
        r.positionKey = cfg.positionKey;
        r.positionId = cfg.positionId;
        r.desk = cfg.maker;
        r.taker = msg.sender;
        r.poolIdA = cfg.poolIdA;
        r.poolIdB = cfg.poolIdB;
        r.tokenA = cfg.tokenA;
        r.tokenB = cfg.tokenB;
        r.baseIsA = cfg.baseIsA;
        r.asset = expectedAsset;
        r.amount = amount;
        r.settlementDigest = settlementDigest;
        r.hashlock = bytes32(0);
        r.counter = counter;
        r.expiry = expiry;
        r.createdAt = uint64(block.timestamp);
        r.feeBps = tranche.feeBps;
        r.feePayer = tranche.feePayer;
        r.status = AtomicTypes.ReservationStatus.Active;

        st.reservationTranche[reservationId] = trancheId;

        if (st.mailbox != address(0)) {
            IMailbox(st.mailbox).authorizeReservation(reservationId);
        }

        emit ReservationCreated(reservationId, msg.sender, cfg.maker, amount, counter);
        emit AtomicDeskReservationCreated(
            reservationId,
            tranche.deskId,
            msg.sender,
            expectedAsset,
            amount,
            settlementDigest,
            expiry,
            uint64(block.timestamp)
        );
        emit TrancheReserved(trancheId, reservationId, msg.sender, amount, tranche.remainingLiquidity);
    }

    function reserveAtomicSwap(
        bytes32 deskId,
        address taker,
        address asset,
        uint256 amount,
        bytes32 settlementDigest,
        uint64 expiry
    ) external payable nonReentrant returns (bytes32 reservationId) {
        LibCurrency.assertZeroMsgValue();

        LibAtomicStorage.AtomicStorage storage st = LibAtomicStorage.atomicStorage();
        if (st.atomicPaused) revert AtomicDesk_Paused();

        AtomicTypes.DeskConfig storage cfg = st.desks[deskId];
        if (!cfg.active || cfg.maker == address(0)) revert AtomicDesk_InvalidDesk();
        if (cfg.maker != msg.sender) revert AtomicDesk_InvalidDesk();
        if (taker == address(0) || taker == cfg.maker) revert AtomicDesk_InvalidTaker();
        if (amount == 0) revert AtomicDesk_InvalidAmount();
        if (settlementDigest == bytes32(0)) revert AtomicDesk_InvalidSettlementDigest();

        uint256 nowTs = block.timestamp;
        if (expiry <= nowTs) revert AtomicDesk_InvalidExpiry();
        uint256 minExpiry = nowTs + MIN_EXPIRY_WINDOW;
        if (expiry < minExpiry) revert AtomicDesk_InvalidExpiry();
        uint256 maxExpiry = nowTs + st.refundSafetyWindow;
        if (st.refundSafetyWindow == 0 || expiry > maxExpiry) revert AtomicDesk_InvalidExpiry();

        address expectedAsset = cfg.baseIsA ? cfg.tokenA : cfg.tokenB;
        if (asset != expectedAsset) revert AtomicDesk_IncorrectAsset(asset);

        bytes32 positionKey = LibDerivativeHelpers._requirePositionOwnership(cfg.positionId);
        if (positionKey != cfg.positionKey) revert AtomicDesk_InvalidDesk();

        LibFeeIndex.settle(cfg.poolIdA, positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdA, positionKey);
        LibFeeIndex.settle(cfg.poolIdB, positionKey);
        LibActiveCreditIndex.settle(cfg.poolIdB, positionKey);

        uint256 basePoolId = cfg.baseIsA ? cfg.poolIdA : cfg.poolIdB;
        LibDerivativeHelpers._lockCollateral(positionKey, basePoolId, amount);

        uint256 counter = ++st.reservationCounter;
        reservationId = keccak256(abi.encodePacked(block.timestamp, positionKey, counter));

        AtomicTypes.Reservation storage r = st.reservations[reservationId];
        r.reservationId = reservationId;
        r.deskId = deskId;
        r.positionKey = positionKey;
        r.positionId = cfg.positionId;
        r.desk = cfg.maker;
        r.taker = taker;
        r.poolIdA = cfg.poolIdA;
        r.poolIdB = cfg.poolIdB;
        r.tokenA = cfg.tokenA;
        r.tokenB = cfg.tokenB;
        r.baseIsA = cfg.baseIsA;
        r.asset = expectedAsset;
        r.amount = amount;
        r.settlementDigest = settlementDigest;
        r.hashlock = bytes32(0);
        r.counter = counter;
        r.expiry = expiry;
        r.createdAt = uint64(block.timestamp);
        r.feeBps = 0;
        r.feePayer = AtomicTypes.FeePayer.Maker;
        r.status = AtomicTypes.ReservationStatus.Active;

        if (st.mailbox != address(0)) {
            IMailbox(st.mailbox).authorizeReservation(reservationId);
        }

        emit ReservationCreated(reservationId, taker, cfg.maker, amount, counter);
        emit AtomicDeskReservationCreated(
            reservationId,
            deskId,
            taker,
            expectedAsset,
            amount,
            settlementDigest,
            expiry,
            uint64(block.timestamp)
        );
    }

    function setHashlock(bytes32 reservationId, bytes32 hashlock) external {
        AtomicTypes.Reservation storage r = LibAtomicStorage.atomicStorage().reservations[reservationId];
        if (r.status != AtomicTypes.ReservationStatus.Active) {
            revert AtomicDesk_ReservationNotActive(reservationId);
        }
        if (r.desk != msg.sender) revert AtomicDesk_InvalidDesk();
        if (r.hashlock != bytes32(0)) {
            revert AtomicDesk_HashlockAlreadySet(reservationId);
        }
        if (hashlock == bytes32(0)) revert AtomicDesk_InvalidSettlementDigest();

        r.hashlock = hashlock;
        emit HashlockSet(reservationId, hashlock);
    }

    function getReservation(bytes32 reservationId)
        external
        view
        returns (AtomicTypes.Reservation memory)
    {
        AtomicTypes.Reservation storage r = LibAtomicStorage.atomicStorage().reservations[reservationId];
        if (r.reservationId == bytes32(0)) {
            revert AtomicDesk_ReservationNotActive(reservationId);
        }
        return r;
    }

    function _canonicalPools(uint256 poolIdA, uint256 poolIdB, bool baseIsA)
        internal
        pure
        returns (uint256, uint256, bool)
    {
        if (poolIdA == poolIdB) revert AtomicDesk_InvalidPool(poolIdA);
        if (poolIdA > poolIdB) {
            (poolIdA, poolIdB) = (poolIdB, poolIdA);
            baseIsA = !baseIsA;
        }
        return (poolIdA, poolIdB, baseIsA);
    }

    function _requireDeskOwner(AtomicTypes.DeskConfig storage cfg) internal view {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        if (nft.ownerOf(cfg.positionId) != cfg.maker) revert AtomicDesk_InvalidDesk();
    }

    function _availablePrincipal(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        Types.PoolData storage pool = LibDirectHelpers._pool(poolId);
        uint256 principal = pool.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 used = enc.directLocked + enc.directLent;
        return principal > used ? principal - used : 0;
    }

    function _validateFeeConfig(uint16 feeBps, AtomicTypes.FeePayer feePayer) internal pure {
        if (feeBps > BPS_DENOMINATOR) revert AtomicDesk_InvalidFeeBps(feeBps);
        if (uint8(feePayer) > uint8(AtomicTypes.FeePayer.Taker)) {
            revert AtomicDesk_InvalidFeePayer();
        }
    }

    function _applyMakerFee(uint256 poolId, bytes32 positionKey, uint256 amount, uint16 feeBps) internal {
        if (feeBps == 0) return;
        uint256 feeAmount = (amount * feeBps) / BPS_DENOMINATOR;
        if (feeAmount == 0) return;
        uint256 makerShare = (feeAmount * MAKER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 protocolFee = feeAmount - makerShare;
        if (protocolFee == 0) return;

        Types.PoolData storage pool = LibDirectHelpers._pool(poolId);
        pool.userPrincipal[positionKey] -= protocolFee;
        pool.totalDeposits = pool.totalDeposits >= protocolFee ? pool.totalDeposits - protocolFee : 0;

        LibFeeRouter.routeSamePool(poolId, protocolFee, ATOMIC_SWAP_FEE_SOURCE, true, 0);
    }

    function _collectTakerTranchePostingFee(uint256 feeWei) internal {
        if (feeWei == 0) {
            LibCurrency.assertZeroMsgValue();
            return;
        }
        if (msg.value != feeWei) {
            revert AtomicDesk_InvalidPostingFee(feeWei, msg.value);
        }
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0)) revert InvalidTreasuryAddress();
        LibCurrency.transfer(address(0), treasury, feeWei);
    }
}

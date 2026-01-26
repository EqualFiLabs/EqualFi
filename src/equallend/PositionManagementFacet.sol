// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibActionFees} from "../libraries/LibActionFees.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {
    NotNFTOwner,
    DepositBelowMinimum,
    PoolNotInitialized,
    InsufficientPoolLiquidity,
    InsufficientPrincipal,
    ActiveLoansExist,
    SolvencyViolation,
    LoanBelowMinimum,
    DepositCapExceeded,
    MaxUserCountExceeded,
    InvalidFeeReceiver,
    UnexpectedMsgValue
} from "../libraries/Errors.sol";

/// @title PositionManagementFacet
/// @notice Handles Position NFT lifecycle operations (minting, deposits, withdrawals, yield rolling)
contract PositionManagementFacet is ReentrancyGuardModifiers {

    /// @notice Emitted when a Position NFT is minted
    event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);

    /// @notice Emitted when capital is deposited to a Position NFT
    event DepositedToPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 amount,
        uint256 newPrincipal
    );

    /// @notice Emitted when capital is withdrawn from a Position NFT
    event WithdrawnFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 principalWithdrawn,
        uint256 yieldWithdrawn,
        uint256 remainingPrincipal
    );

    /// @notice Emitted when yield is rolled into principal for a Position NFT
    event YieldRolledToPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 yieldAmount,
        uint256 newPrincipal
    );

    /// @notice Get the app storage
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    /// @notice Get a pool by ID with validation
    /// @param pid The pool ID
    /// @return The pool data storage reference
    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibPositionHelpers.pool(pid);
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
        return p;
    }

    /// @notice Require that the caller owns the specified NFT
    /// @param tokenId The token ID to check ownership for
    function _requireOwnership(uint256 tokenId) internal view {
        LibPositionHelpers.requireOwnership(tokenId);
    }

    /// @notice Get the position key for a token ID
    /// @param tokenId The token ID
    /// @return The position key (address used in PoolData mappings)
    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    /// @notice Attempt to clean up pool membership when obligations are clear.
    /// @param tokenId The position NFT
    /// @param pid The pool to clear membership from
    function cleanupMembership(uint256 tokenId, uint256 pid) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        _requireOwnership(tokenId);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);
        (bool canClear, string memory reason) = LibPoolMembership.canClearMembership(positionKey, pid);
        LibPoolMembership._leavePool(positionKey, pid, canClear, reason);
    }

    function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) internal returns (bool) {
        return LibPositionHelpers.ensurePoolMembership(positionKey, pid, allowAutoJoin);
    }

    function _mintFeeConfig() internal view returns (address feeToken, uint256 feeAmount) {
        LibAppStorage.AppStorage storage store = s();
        feeToken = store.positionMintFeeToken;
        feeAmount = store.positionMintFeeAmount;
    }

    function _assertMintMsgValue(address underlying, uint256 depositAmount)
        internal
        view
        returns (address feeToken, uint256 feeAmount)
    {
        (feeToken, feeAmount) = _mintFeeConfig();
        bool nativeUnderlying = LibCurrency.isNative(underlying);
        bool nativeFee = feeAmount > 0 && LibCurrency.isNative(feeToken);
        uint256 nativeRequired = 0;
        if (nativeUnderlying) {
            nativeRequired += depositAmount;
        }
        if (nativeFee) {
            nativeRequired += feeAmount;
        }
        if (nativeRequired == 0) {
            if (msg.value != 0) {
                revert UnexpectedMsgValue(msg.value);
            }
            return (feeToken, feeAmount);
        }
        if (!nativeUnderlying || depositAmount == 0 || nativeFee) {
            if (msg.value != nativeRequired) {
                revert UnexpectedMsgValue(msg.value);
            }
            return (feeToken, feeAmount);
        }
        if (msg.value == nativeRequired) {
            return (feeToken, feeAmount);
        }
        if (msg.value != 0) {
            revert UnexpectedMsgValue(msg.value);
        }
        uint256 available = LibCurrency.nativeAvailable();
        if (available < nativeRequired) {
            revert InsufficientPoolLiquidity(nativeRequired, available);
        }
    }

    function _collectMintFee(address payer, address feeToken, uint256 feeAmount) internal {
        if (feeAmount == 0) {
            return;
        }
        LibAppStorage.AppStorage storage store = s();
        address treasury = LibAppStorage.treasuryAddress(store);
        if (treasury == address(0)) {
            revert InvalidFeeReceiver();
        }
        if (LibCurrency.isNative(feeToken)) {
            LibCurrency.transfer(address(0), treasury, feeAmount);
            return;
        }
        uint256 received = LibCurrency.pull(feeToken, payer, feeAmount);
        require(received == feeAmount, "PositionNFT: fee short");
        LibCurrency.transfer(feeToken, treasury, received);
    }

    function _pullMintDeposit(address token, uint256 amount) internal returns (uint256 received) {
        if (!LibCurrency.isNative(token)) {
            return LibCurrency.pull(token, msg.sender, amount);
        }
        if (amount == 0) {
            return 0;
        }
        LibAppStorage.s().nativeTrackedTotal += amount;
        return amount;
    }

    /// @notice Check solvency for a position using only on-chain deterministic data
    /// @dev This function ensures NRF compliance by using only immutable pool config and on-chain state
    /// @param p The pool data storage reference
    /// @param positionKey The position key to check
    /// @param newPrincipal The principal amount after the proposed operation
    /// @param newDebt The total debt after the proposed operation
    /// @return isSolvent True if the position is solvent
    function _checkSolvency(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 newPrincipal,
        uint256 newDebt
    ) internal view returns (bool isSolvent) {
        return LibSolvencyChecks.checkSolvency(p, positionKey, newPrincipal, newDebt);
    }

    /// @notice Calculate total debt for a position using only on-chain data
    /// @dev Returns the sum of all active loan principals (rolling + fixed-term + direct)
    function _calculateTotalDebt(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 totalDebt) {
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function _enforceDepositCap(Types.PoolData storage p, uint256 newPrincipal) internal view {
        if (p.poolConfig.isCapped) {
            uint256 cap = p.poolConfig.depositCap;
            if (cap > 0 && newPrincipal > cap) {
                revert DepositCapExceeded(newPrincipal, cap);
            }
        }
    }

    function _enforceMaxUsers(Types.PoolData storage p, bool isNewUser) internal view {
        if (!isNewUser) return;
        uint256 maxUsers = p.poolConfig.maxUserCount;
        if (maxUsers > 0 && p.userCount >= maxUsers) {
            revert MaxUserCountExceeded(maxUsers);
        }
    }

    function _incrementUserCount(Types.PoolData storage p, bool isNewUser, uint256 newPrincipal) internal {
        if (isNewUser && newPrincipal > 0) {
            p.userCount += 1;
        }
    }

    function _decrementUserCountIfEmpty(Types.PoolData storage p, uint256 prevPrincipal, uint256 newPrincipal)
        internal
    {
        if (prevPrincipal > 0 && newPrincipal == 0 && p.userCount > 0) {
            p.userCount -= 1;
        }
    }

    /// @notice Mint a new Position NFT for a pool
    /// @param pid The pool ID
    /// @return tokenId The newly minted token ID
    function mintPosition(uint256 pid) external payable nonReentrant returns (uint256 tokenId) {
        // Validate pool exists
        Types.PoolData storage p = _pool(pid);
        (address feeToken, uint256 feeAmount) = _assertMintMsgValue(p.underlying, 0);
        _collectMintFee(msg.sender, feeToken, feeAmount);

        // Mint the NFT
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        tokenId = nft.mint(msg.sender, pid);

        emit PositionMinted(tokenId, msg.sender, pid);
    }

    /// @notice Mint a new Position NFT with an initial deposit
    /// @param pid The pool ID
    /// @param amount The initial deposit amount
    /// @return tokenId The newly minted token ID
    function mintPositionWithDeposit(uint256 pid, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        Types.PoolData storage p = _pool(pid);
        require(amount > 0, "PositionNFT: amount=0");
        (address feeToken, uint256 feeAmount) = _assertMintMsgValue(p.underlying, amount);

        _enforceMaxUsers(p, true);
        _collectMintFee(msg.sender, feeToken, feeAmount);

        // Mint the NFT
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        tokenId = nft.mint(msg.sender, pid);

        // Get position key for the new NFT
        bytes32 positionKey = _getPositionKey(tokenId);

        // For managed pools, whitelist manager-minted tokens to permit initial deposit
        if (p.isManagedPool && p.whitelistEnabled && msg.sender == p.manager && !p.whitelist[positionKey]) {
            p.whitelist[positionKey] = true;
        }
        _ensurePoolMembership(positionKey, pid, true);

        // Transfer tokens from user to contract and credit actual received (handles fee-on-transfer tokens)
        uint256 received = _pullMintDeposit(p.underlying, amount);
        if (received < p.poolConfig.minDepositAmount) {
            revert DepositBelowMinimum(received, p.poolConfig.minDepositAmount);
        }
        _enforceDepositCap(p, received);

        // Update position state
        p.userPrincipal[positionKey] = received;
        p.totalDeposits += received;
        p.trackedBalance += received;
        _incrementUserCount(p, true, received);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;

        emit PositionMinted(tokenId, msg.sender, pid);
        emit DepositedToPosition(tokenId, msg.sender, pid, received, received);
    }

    /// @notice Deposit capital to an existing Position NFT
    /// @param tokenId The token ID
    /// @param amount The amount to deposit
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) public payable nonReentrant {
        // Verify ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        require(amount > 0, "PositionNFT: amount=0");
        LibCurrency.assertMsgValue(p.underlying, amount);

        // Settle fees before updating principal
        LibFeeIndex.settle(pid, positionKey);

        uint256 currentPrincipal = p.userPrincipal[positionKey];
        bool isNewUser = currentPrincipal == 0;
        _enforceMaxUsers(p, isNewUser);

        // Transfer tokens from user to contract and credit actual received
        uint256 received = LibCurrency.pull(p.underlying, msg.sender, amount);
        if (received < p.poolConfig.minDepositAmount) {
            revert DepositBelowMinimum(received, p.poolConfig.minDepositAmount);
        }

        // Update position state
        uint256 newPrincipal = currentPrincipal + received;
        _enforceDepositCap(p, newPrincipal);
        p.userPrincipal[positionKey] = newPrincipal;
        _incrementUserCount(p, isNewUser, newPrincipal);
        p.totalDeposits += received;
        p.trackedBalance += received;
        p.userFeeIndex[positionKey] = p.feeIndex;

        emit DepositedToPosition(tokenId, msg.sender, pid, received, p.userPrincipal[positionKey]);
    }

    /// @notice Withdraw capital from a Position NFT
    /// @param tokenId The token ID
    /// @param principalToWithdraw The amount of principal to withdraw
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 principalToWithdraw) public payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        // Verify ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        require(principalToWithdraw > 0, "PositionNFT: amount=0");

        // Settle Fee Index + Active Credit Index before withdrawal
        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);

        // Get current principal after settlement
        uint256 currentPrincipal = p.userPrincipal[positionKey];

        // Enforce Direct commitments (locked + escrow) remain after withdrawal
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 totalEncumbered =
            enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;

        // Charge ACTION_WITHDRAW fee from position principal before solvency check
        uint256 feeAmount = LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_WITHDRAW, positionKey);
        currentPrincipal = p.userPrincipal[positionKey];

        if (totalEncumbered > currentPrincipal) {
            revert InsufficientPrincipal(totalEncumbered, currentPrincipal);
        }
        uint256 availablePrincipal = currentPrincipal - totalEncumbered;

        // Check sufficient principal after fee is applied
        if (principalToWithdraw > availablePrincipal) {
            revert InsufficientPrincipal(principalToWithdraw, availablePrincipal);
        }

        // Calculate proportional yield to withdraw
        uint256 accruedYield = p.userAccruedYield[positionKey];
        uint256 yieldToWithdraw = 0;

        if (currentPrincipal > 0 && accruedYield > 0) {
            // Proportional yield: (principalToWithdraw / currentPrincipal) * accruedYield
            yieldToWithdraw = (principalToWithdraw * accruedYield) / currentPrincipal;
        }

        // Calculate new principal after withdrawal
        uint256 newPrincipal = currentPrincipal - principalToWithdraw;

        // Calculate total debt using deterministic on-chain data
        uint256 totalDebt = _calculateTotalDebt(p, positionKey, pid);

        // Verify solvency after withdrawal - must maintain LTV ratio
        if (!_checkSolvency(p, positionKey, newPrincipal, totalDebt)) {
            revert SolvencyViolation(newPrincipal, totalDebt, p.poolConfig.depositorLTVBps);
        }

        if (yieldToWithdraw > 0) {
            if (p.yieldReserve < yieldToWithdraw) {
                revert InsufficientPoolLiquidity(yieldToWithdraw, p.yieldReserve);
            }
            p.yieldReserve -= yieldToWithdraw;
        }

        // Update position state
        p.userPrincipal[positionKey] = newPrincipal;
        p.userAccruedYield[positionKey] = accruedYield - yieldToWithdraw;
        p.totalDeposits -= principalToWithdraw;
        _decrementUserCountIfEmpty(p, currentPrincipal + feeAmount, newPrincipal);
        // Only subtract principal from tracked balance, yield comes from fee accrual
        uint256 totalWithdrawal = principalToWithdraw + yieldToWithdraw;
        require(p.trackedBalance >= totalWithdrawal, "PositionNFT: insufficient pool liquidity");
        p.trackedBalance -= totalWithdrawal;
        if (LibCurrency.isNative(p.underlying) && totalWithdrawal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= totalWithdrawal;
        }

        // Transfer tokens from pool to NFT owner
        LibCurrency.transfer(p.underlying, msg.sender, totalWithdrawal);

        emit WithdrawnFromPosition(tokenId, msg.sender, pid, principalToWithdraw, yieldToWithdraw, newPrincipal);
    }

    /// @notice Withdraw all available principal (and proportional yield) from a Position NFT for a pool
    /// @dev Leaves any Direct commitments (locked or lent) intact; reverts if nothing withdrawable
    /// @param tokenId The token ID
    /// @param pid The pool ID
    function closePoolPosition(uint256 tokenId, uint256 pid) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        _requireOwnership(tokenId);

        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        // Settle Fee Index + Active Credit Index before withdrawal
        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);

        uint256 currentPrincipal = p.userPrincipal[positionKey];

        // Respect Direct commitments
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 totalEncumbered =
            enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;

        // Charge ACTION_WITHDRAW fee before solvency check
        uint256 feeAmount = LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_WITHDRAW, positionKey);
        currentPrincipal = p.userPrincipal[positionKey];
        uint256 accruedYield = p.userAccruedYield[positionKey];

        if (totalEncumbered > currentPrincipal) {
            revert InsufficientPrincipal(totalEncumbered, currentPrincipal);
        }

        uint256 principalToWithdraw = currentPrincipal - totalEncumbered;
        require(principalToWithdraw > 0, "PositionNFT: nothing to withdraw");

        uint256 yieldToWithdraw = 0;
        if (currentPrincipal > 0 && accruedYield > 0) {
            yieldToWithdraw = (principalToWithdraw * accruedYield) / currentPrincipal;
        }

        uint256 newPrincipal = currentPrincipal - principalToWithdraw;
        uint256 totalDebt = _calculateTotalDebt(p, positionKey, pid);
        if (!_checkSolvency(p, positionKey, newPrincipal, totalDebt)) {
            revert SolvencyViolation(newPrincipal, totalDebt, p.poolConfig.depositorLTVBps);
        }

        if (yieldToWithdraw > 0) {
            if (p.yieldReserve < yieldToWithdraw) {
                revert InsufficientPoolLiquidity(yieldToWithdraw, p.yieldReserve);
            }
            p.yieldReserve -= yieldToWithdraw;
        }

        p.userPrincipal[positionKey] = newPrincipal;
        p.userAccruedYield[positionKey] = accruedYield - yieldToWithdraw;
        require(p.totalDeposits >= principalToWithdraw, "PositionNFT: insufficient tracked deposits");
        p.totalDeposits -= principalToWithdraw;
        _decrementUserCountIfEmpty(p, currentPrincipal + feeAmount, newPrincipal);

        uint256 totalWithdrawal = principalToWithdraw + yieldToWithdraw;
        require(p.trackedBalance >= totalWithdrawal, "PositionNFT: insufficient pool liquidity");
        p.trackedBalance -= totalWithdrawal;
        if (LibCurrency.isNative(p.underlying) && totalWithdrawal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= totalWithdrawal;
        }

        LibCurrency.transfer(p.underlying, msg.sender, totalWithdrawal);

        emit WithdrawnFromPosition(tokenId, msg.sender, pid, principalToWithdraw, yieldToWithdraw, newPrincipal);

        // Clear membership if all obligations are settled
        (bool canClear, string memory reason) = LibPoolMembership.canClearMembership(positionKey, pid);
        if (canClear) {
            LibPoolMembership._leavePool(positionKey, pid, canClear, reason);
        }
    }

    /// @notice Roll accrued yield into principal for a Position NFT
    /// @param tokenId The token ID
    function rollYieldToPosition(uint256 tokenId, uint256 pid) public payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        // Verify ownership
        _requireOwnership(tokenId);

        // Get pool and position key
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);

        // Settle Fee Index + Active Credit Index to calculate accrued yield
        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);

        // Get accrued yield after settlement
        uint256 accruedYield = p.userAccruedYield[positionKey];

        require(accruedYield > 0, "PositionNFT: no yield to roll");

        if (p.yieldReserve < accruedYield) {
            revert InsufficientPoolLiquidity(accruedYield, p.yieldReserve);
        }

        // Roll accrued yield into principal
        p.userPrincipal[positionKey] += accruedYield;
        p.userAccruedYield[positionKey] = 0;
        p.yieldReserve -= accruedYield;
        // Move rolled yield into the tracked pool balance so deposits stay fully backed.
        p.trackedBalance += accruedYield;
        if (LibCurrency.isNative(p.underlying) && accruedYield > 0) {
            LibAppStorage.s().nativeTrackedTotal += accruedYield;
        }

        // Update total deposits to reflect the rolled yield
        p.totalDeposits += accruedYield;

        emit YieldRolledToPosition(tokenId, msg.sender, pid, accruedYield, p.userPrincipal[positionKey]);
    }

}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Multi-token faucet with per-token amounts and a global claim cooldown.
contract Faucet is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CLAIM_INTERVAL = 1 days;

    struct TokenConfig {
        uint256 amount;
        bool enabled;
        bool exists;
    }

    mapping(address => TokenConfig) private tokenConfig;
    address[] private tokens;
    mapping(address => uint64) public lastClaimAt;

    error Faucet_ClaimTooSoon(uint256 nextAllowed);
    error Faucet_InvalidToken(address token);
    error Faucet_TokenNotConfigured(address token);
    error Faucet_InsufficientBalance(address token, uint256 required, uint256 balance);

    event TokenConfigured(address indexed token, uint256 amount, bool enabled);
    event Claimed(address indexed user, uint256 timestamp);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Add or update a token configuration.
    function setToken(address token, uint256 amount, bool enabled) external onlyOwner {
        if (token == address(0)) revert Faucet_InvalidToken(token);
        TokenConfig storage cfg = tokenConfig[token];
        if (!cfg.exists) {
            cfg.exists = true;
            tokens.push(token);
        }
        cfg.amount = amount;
        cfg.enabled = enabled;
        emit TokenConfigured(token, amount, enabled);
    }

    /// @notice Update the amount for an existing token.
    function setTokenAmount(address token, uint256 amount) external onlyOwner {
        TokenConfig storage cfg = tokenConfig[token];
        if (!cfg.exists) revert Faucet_TokenNotConfigured(token);
        cfg.amount = amount;
        emit TokenConfigured(token, amount, cfg.enabled);
    }

    /// @notice Enable/disable an existing token.
    function setTokenEnabled(address token, bool enabled) external onlyOwner {
        TokenConfig storage cfg = tokenConfig[token];
        if (!cfg.exists) revert Faucet_TokenNotConfigured(token);
        cfg.enabled = enabled;
        emit TokenConfigured(token, cfg.amount, enabled);
    }

    /// @notice Claim faucet amounts for all enabled tokens.
    function claim() external nonReentrant {
        uint64 last = lastClaimAt[msg.sender];
        uint64 nowTs = uint64(block.timestamp);
        if (last != 0 && nowTs < last + CLAIM_INTERVAL) {
            revert Faucet_ClaimTooSoon(last + uint64(CLAIM_INTERVAL));
        }
        lastClaimAt[msg.sender] = nowTs;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            TokenConfig memory cfg = tokenConfig[token];
            if (!cfg.enabled || cfg.amount == 0) continue;

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < cfg.amount) {
                revert Faucet_InsufficientBalance(token, cfg.amount, balance);
            }
            IERC20(token).safeTransfer(msg.sender, cfg.amount);
        }

        emit Claimed(msg.sender, block.timestamp);
    }

    /// @notice Withdraw tokens from the faucet.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert Faucet_InvalidToken(token);
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function getTokens() external view returns (address[] memory) {
        return tokens;
    }

    function getTokenConfig(address token) external view returns (uint256 amount, bool enabled, bool exists) {
        TokenConfig memory cfg = tokenConfig[token];
        return (cfg.amount, cfg.enabled, cfg.exists);
    }

    function nextClaimAt(address user) external view returns (uint256) {
        uint64 last = lastClaimAt[user];
        if (last == 0) return 0;
        return uint256(last + uint64(CLAIM_INTERVAL));
    }
}

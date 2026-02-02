// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../src/libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../src/libraries/LibPositionHelpers.sol";
import {Types} from "../src/libraries/Types.sol";
import {LibCurrency} from "../src/libraries/LibCurrency.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

// Mock NFT to satisfy ownership and key derivation checks
contract MockPositionNFT {
    function ownerOf(uint256) external view returns (address) {
        // Always return msg.sender (the Echidna caller) so checks pass
        return msg.sender;
    }
    
    function getPositionKey(uint256 tokenId) external pure returns (bytes32) {
        // Mock deterministic key
        return keccak256(abi.encodePacked(tokenId));
    }
    
    function getPoolId(uint256 tokenId) external pure returns (uint256) {
        // Assume tokenId matches poolId for this simple mock, or just return 1
        return 1;
    }
}

contract EchidnaLendingFacet is LendingFacet {
    MockERC20 internal token;
    MockPositionNFT internal mockNft;
    
    // Test constants
    uint256 internal constant PID = 1;
    uint256 internal constant TOKEN_ID = 1;
    
    constructor() {
        // Setup mock token (name, symbol, decimals, initialSupply)
        token = new MockERC20("Test", "TEST", 18, 1_000_000 ether);
        mockNft = new MockPositionNFT();
        
        // Setup storage for PositionNFT
        LibPositionNFT.PositionNFTStorage storage pns = LibPositionNFT.s();
        pns.positionNFTContract = address(mockNft);
        pns.nftModeEnabled = true;
        
        // Initialize pool
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        p.initialized = true;
        p.underlying = address(token);
        p.poolConfig.depositorLTVBps = 5000; // 50% LTV
        p.poolConfig.minLoanAmount = 100;
        p.poolConfig.minTopupAmount = 100;
        
        // Give initial liquidity to pool (already minted to this contract in MockERC20 constructor if it was msg.sender,
        // but Echidna calls constructor. Who is msg.sender? This contract? Or deployer?
        // MockERC20 mints to msg.sender. Since 'new MockERC20' is called by THIS contract, THIS contract gets tokens.
        p.trackedBalance = 1_000_000 ether;
        p.totalDeposits = 1_000_000 ether; 
    }
    
    // ========== ACTIONS ==========

    function action_deposit(uint128 amount) public {
        if (amount == 0) return;
        
        // Simulate deposit logic
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        
        // Use the mocked NFT key
        bytes32 posKey = mockNft.getPositionKey(TOKEN_ID);
        p.userPrincipal[posKey] += amount;
        p.totalDeposits += amount;
        p.trackedBalance += amount;
        
        // Mint tokens to contract to back the deposit
        token.mint(address(this), amount);
    }
    
    function action_borrow(uint128 amount) public {
        // Call directly (preserves msg.sender = Echidna caller)
        // If it reverts (insolvency), Echidna discards the sequence.
        super.openRollingFromPosition(TOKEN_ID, PID, amount);
    }

    // ========== INVARIANTS ==========

    /// @notice Solvency Invariant: Active loan implies valid debt state
    function echidna_solvency_invariant() public view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        bytes32 posKey = mockNft.getPositionKey(TOKEN_ID);
        
        if (p.rollingLoans[posKey].active) {
            uint256 debt = p.rollingLoans[posKey].principalRemaining;
            if (debt == 0) return false; // Active but no debt?
        }
        return true;
    }
    
    /// @notice Accounting Invariant: Tracked balance + Reserves matches token balance
    function echidna_liquidity_invariant() public view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        
        uint256 actualBalance = token.balanceOf(address(this));
        uint256 internalTotal = p.trackedBalance + p.yieldReserve + p.feeIndexRemainder;
        
        return actualBalance == internalTotal;
    }

    // Debug getters
    function debug_accounting() public view returns (uint256 tracked, uint256 reserve, uint256 remainder, uint256 actual) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        tracked = p.trackedBalance;
        reserve = p.yieldReserve;
        remainder = p.feeIndexRemainder;
        actual = token.balanceOf(address(this));
    }
}

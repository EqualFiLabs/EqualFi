// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EqualIndexActionsFacetV3} from "../src/equalindex/EqualIndexActionsFacetV3.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../src/libraries/LibEqualIndex.sol";
import {IndexToken} from "../src/equalindex/IndexToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IEqualIndexFlashReceiver} from "../src/equalindex/EqualIndexBaseV3.sol";
import {LibCurrency} from "../src/libraries/LibCurrency.sol";

contract EchidnaEqualIndex is EqualIndexActionsFacetV3, IEqualIndexFlashReceiver {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IndexToken internal indexToken;
    
    uint256 internal constant INDEX_ID = 1;
    
    // Track expected state for invariants
    bool internal flashLoanActive;

    constructor() {
        // 1. Setup Assets
        tokenA = new MockERC20("Token A", "TKNA", 18, 0);
        tokenB = new MockERC20("Token B", "TKNB", 18, 0);

        // 2. Setup Index Definition
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether; // 1 TKNA per unit
        amounts[1] = 2 ether; // 2 TKNB per unit

        // 3. Deploy IndexToken (minter = this)
        indexToken = new IndexToken(
            "Index One", "IDX1", 
            address(this), 
            assets, 
            amounts, 
            500, // 5% flash fee
            INDEX_ID
        );

        // 4. Initialize Storage
        EqualIndexStorage storage store = s();
        store.indexCount = INDEX_ID + 1;

        Index storage idx = store.indexes[INDEX_ID];
        
        idx.assets = assets;
        idx.bundleAmounts = amounts;
        idx.token = address(indexToken);
        // idx.paused is false by default, which means active
        idx.flashFeeBps = 500;
        
        idx.mintFeeBps = new uint16[](2);
        idx.burnFeeBps = new uint16[](2);
        idx.mintFeeBps[0] = 100; // 1%
        idx.mintFeeBps[1] = 100;
        idx.burnFeeBps[0] = 100;
        idx.burnFeeBps[1] = 100;
        
        // Self-approve for actions (since we act as both vault and user)
        tokenA.approve(address(this), type(uint256).max);
        tokenB.approve(address(this), type(uint256).max);
    }
    
    // ========== ACTIONS ==========

    /// @notice Mint index units.
    /// Echidna calls this. We simulate the user being `address(this)`.
    function action_mint(uint128 units) public {
        // Constraint: units must be multiple of 1e18
        if (units == 0) return;
        // Force alignment to 1e18 to hit valid paths more often
        uint256 alignedUnits = (uint256(units) / 1e18) * 1e18;
        if (alignedUnits == 0) alignedUnits = 1e18;
        
        // 1. Mint required assets to this contract (the "user")
        // Calculation: (unit * bundle / 1e18) * (1 + feeBps/10000)
        uint256 reqA = (alignedUnits * 1 ether / 1e18) * 10100 / 10000 + 100; // +buffer
        uint256 reqB = (alignedUnits * 2 ether / 1e18) * 10100 / 10000 + 100;
        
        tokenA.mint(address(this), reqA);
        tokenB.mint(address(this), reqB);
        
        // 2. Call mint (external call to self)
        try this.mint(INDEX_ID, alignedUnits, address(this)) {
            // Success
        } catch {
            // Ignore reverts (invalid inputs etc)
        }
    }

    /// @notice Burn index units.
    function action_burn(uint128 units) public {
        if (units == 0) return;
        uint256 alignedUnits = (uint256(units) / 1e18) * 1e18;
        if (alignedUnits == 0) return;
        
        if (indexToken.balanceOf(address(this)) < alignedUnits) return;
        
        try this.burn(INDEX_ID, alignedUnits, address(this)) {
            // Success
        } catch {
            // Ignore
        }
    }
    
    /// @notice Flash loan.
    function action_flashLoan(uint128 units) public {
        if (units == 0) return;
        uint256 alignedUnits = (uint256(units) / 1e18) * 1e18;
        if (alignedUnits == 0) return;
        
        // Must have enough supply
        if (indexToken.totalSupply() < alignedUnits) return;
        
        try this.flashLoan(INDEX_ID, alignedUnits, address(this), "") {
            // Success
        } catch {
            // Ignore
        }
    }
    
    // ========== CALLBACKS ==========
    
    function onEqualIndexFlashLoan(
        uint256 /*indexId*/,
        uint256 /*units*/,
        address[] calldata assets,
        uint256[] calldata /*amounts*/,
        uint256[] calldata fees,
        bytes calldata /*data*/
    ) external override {
        // Mint fees to self to pay back the loan fee
        for (uint256 i = 0; i < assets.length; i++) {
            MockERC20(assets[i]).mint(address(this), fees[i]);
        }
    }

    // ========== INVARIANTS ==========

    /// @notice Solvency: Contract balance must cover all vault balances + fee pots.
    function echidna_solvency() public view returns (bool) {
        EqualIndexStorage storage store = s();
        
        // Check Token A
        uint256 vaultA = store.vaultBalances[INDEX_ID][address(tokenA)];
        uint256 potA = store.feePots[INDEX_ID][address(tokenA)];
        uint256 actualA = tokenA.balanceOf(address(this));
        
        // We might have extra tokens from "minting to self" that weren't fully used due to rounding/buffer
        // So actual >= liability
        if (actualA < vaultA + potA) return false;
        
        // Check Token B
        uint256 vaultB = store.vaultBalances[INDEX_ID][address(tokenB)];
        uint256 potB = store.feePots[INDEX_ID][address(tokenB)];
        uint256 actualB = tokenB.balanceOf(address(this));
        
        if (actualB < vaultB + potB) return false;
        
        return true;
    }
    
    /// @notice Backing: Total Supply * Bundle Amount <= Vault Balance * Scale
    /// (Strict backing check, assuming no external donations)
    function echidna_backing_integrity() public view returns (bool) {
        EqualIndexStorage storage store = s();
        uint256 supply = indexToken.totalSupply();
        
        uint256 vaultA = store.vaultBalances[INDEX_ID][address(tokenA)];
        uint256 reqA = (supply * 1 ether) / 1e18;
        
        if (reqA > vaultA) return false;
        
        uint256 vaultB = store.vaultBalances[INDEX_ID][address(tokenB)];
        uint256 reqB = (supply * 2 ether) / 1e18;
        if (reqB > vaultB) return false;
        
        return true;
    }
    
    /// @notice Fee Pot Monotonicity (loosely): Fee pots should not decrease unless burned?
    /// Actually, burn redemptions CLAIM from the fee pot. So they can decrease.
    /// But they shouldn't go negative (Solidity handles underflow).
    
    /// @notice Fee Pot Consistency:
    /// If supply > 0, fee pot claims should be proportional.
    
}

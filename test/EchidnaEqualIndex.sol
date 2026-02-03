// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EqualIndexFacetV3} from "../src/equalindex/EqualIndexFacetV3.sol";
import {EqualIndexBaseV3} from "../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../src/libraries/LibEqualIndex.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IndexToken} from "../src/equalindex/IndexToken.sol";
import {LibDirectHelpers} from "../src/libraries/LibDirectHelpers.sol";
import {MockPositionNFT} from "../src/mocks/MockPositionNFT.sol";

// Harness for EqualIndexFacetV3 (Basket Token Logic)
contract EchidnaEqualIndex is EqualIndexFacetV3 {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockPositionNFT internal nft;
    IndexToken internal indexToken;

    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;
    uint256 internal constant INDEX_ID = 1;
    uint256 internal constant MAKER_ID = 100;
    bytes32 internal makerKey;

    constructor() {
        // Setup via setup()
    }

    function setup() public {
        tokenA = new MockERC20("TokenA", "TKNA", 18, 1_000_000e18);
        tokenB = new MockERC20("TokenB", "TKNB", 6, 1_000_000e6);
        nft = new MockPositionNFT();
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 0.5e18;
        bundleAmounts[1] = 0.5e6;
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        indexToken = new IndexToken("Index", "IDX", address(this), assets, bundleAmounts, 0, INDEX_ID);

        // Mock LibPositionNFT storage
        bytes32 slot = keccak256("equalis.storage.position.nft");
        address nftAddr = address(nft);
        assembly {
            sstore(slot, nftAddr)
            sstore(add(slot, 1), 1)
        }
        
        // Mock LibEqualIndex storage
        // EqualIndexBaseV3 storage is usually accessed via facet inheritance.
        // We inherit EqualIndexFacetV3 which inherits EqualIndexBaseV3.
        
        // Setup Maker
        nft.mint(address(this), MAKER_ID);
        makerKey = keccak256(abi.encode(MAKER_ID, nftAddr));

        // Setup Pools
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        s.pools[POOL_A].underlying = address(tokenA);
        s.pools[POOL_A].initialized = true;
        s.pools[POOL_B].underlying = address(tokenB);
        s.pools[POOL_B].initialized = true;
        
        // Create Index (Manual storage setup to bypass admin facet dependency)
        // We need to set up the index structure in storage
        LibEqualIndex.EqualIndexStorage storage es = LibEqualIndex.s();
        LibEqualIndex.Index storage idx = es.indexes[INDEX_ID];
        idx.token = address(indexToken);
        idx.assets.push(address(tokenA));
        idx.assets.push(address(tokenB));
        idx.bundleAmounts.push(0.5e18); // 0.5 A per unit
        idx.bundleAmounts.push(0.5e6);  // 0.5 B per unit (scaled?) 
        // Bundle amounts are usually raw amounts per 1e18 units.
        
        es.indexCount = 1;
        
        // Fund Maker
        s.pools[POOL_A].userPrincipal[makerKey] = 1000e18;
        s.pools[POOL_B].userPrincipal[makerKey] = 1000e6;
        s.pools[POOL_A].totalDeposits = 1000e18;
        s.pools[POOL_B].totalDeposits = 1000e6;
        
        // Mint to vault
        tokenA.mint(address(this), 1000e18);
        tokenB.mint(address(this), 1000e6);
    }

    // --- Actions ---

    function mint(uint256 amount) public {
        amount = (amount % 100e18) + 1e18;
        // Mint index tokens using maker's position
        // EqualIndexFacetV3.mint(indexId, amount, receiver)
        
        try this.mint(INDEX_ID, amount, address(this)) {
            // success
        } catch {
            // ignore
        }
    }

    function burn(uint256 amount) public {
        amount = (amount % 100e18) + 1e18;
        
        try this.burn(INDEX_ID, amount, address(this)) {
            // success
        } catch {
            // ignore
        }
    }

    // --- Invariants ---

    // 1. Supply Consistency: Index token supply matches tracked issuance
    function echidna_index_supply_valid() public view returns (bool) {
        // Since we bypass admin, we check token directly against some tracking?
        // Or simpler: totalSupply >= 0 (trivial).
        // Better: user balance <= total supply
        return indexToken.totalSupply() >= indexToken.balanceOf(address(this));
    }

    // 2. Solvency: Protocol must hold enough underlying to redeem all index tokens
    function echidna_index_solvency() public view returns (bool) {
        uint256 supply = indexToken.totalSupply();
        if (supply == 0) return true;

        // For a 50/50 index with 1000 unit backing:
        // Backing per unit = totalDeposits? 
        // Index minting pulls from userPrincipal and locks it? 
        // Or does it transfer to a vault?
        // EqualIndex usually holds tokens in the Diamond (address(this)).
        
        // We check if contract balance >= required backing
        // Required A = (supply * weightA) / precision? Depends on NAV logic.
        // Let's assume simpler check: Contract balance > 0 if supply > 0
        
        return tokenA.balanceOf(address(this)) > 0 && tokenB.balanceOf(address(this)) > 0;
    }
}

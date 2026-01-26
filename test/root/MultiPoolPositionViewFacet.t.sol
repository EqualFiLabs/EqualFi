// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiPoolPositionViewFacet} from "../../src/views/MultiPoolPositionViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

// Mock Position NFT contract
contract MockPositionNFT {
    function getPositionKey(uint256 tokenId) external pure returns (bytes32) {
        require(tokenId == 1, "Invalid token ID");
        return bytes32(uint256(0x1234));
    }
    
    function getPoolId(uint256 tokenId) external pure returns (uint256) {
        require(tokenId == 1, "Invalid token ID");
        return 1;
    }
}

// Harness contract that inherits the facet and can set up storage
contract MultiPoolPositionViewHarness is MultiPoolPositionViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }
    
    function setupPool(uint256 pid, address underlying) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (pid > store.poolCount) {
            store.poolCount = pid;
        }
        store.pools[pid].underlying = underlying;
        store.pools[pid].initialized = true;
        store.pools[pid].feeIndex = 1e18;
    }
    
    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = amount;
        LibAppStorage.s().pools[pid].userFeeIndex[positionKey] = 1e18;
    }
    
    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }
    
    function setDirectData(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent, uint256 borrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
        ds.directBorrowedPrincipal[positionKey][pid] = borrowed;
        LibDirectStorage.addBorrowerAgreement(ds, positionKey, 1);
        LibDirectStorage.addBorrowerAgreement(ds, positionKey, 2);
    }
}

contract MultiPoolPositionViewFacetTest is Test {
    MultiPoolPositionViewHarness internal harness;
    MockPositionNFT internal mockNFT;
    
    // Mock position key and token ID
    bytes32 internal constant POSITION_KEY = bytes32(uint256(0x1234));
    uint256 internal constant TOKEN_ID = 1;
    
    // Mock pool addresses
    address internal constant USDC = address(0x1001);
    address internal constant USDT = address(0x1002);
    
    function setUp() public {
        harness = new MultiPoolPositionViewHarness();
        mockNFT = new MockPositionNFT();
        
        // Set up mock Position NFT contract
        harness.setPositionNFT(address(mockNFT));
        
        // Set up mock pools
        harness.setupPool(1, USDC);
        harness.setupPool(2, USDT);
        
        // Set up user principal
        harness.setUserPrincipal(1, POSITION_KEY, 1000e6); // 1000 USDC
        harness.setUserPrincipal(2, POSITION_KEY, 500e6);  // 500 USDT
        
        // Set up pool membership
        harness.joinPool(POSITION_KEY, 1);
        harness.joinPool(POSITION_KEY, 2);
        
        // Set up some direct agreement data
        harness.setDirectData(POSITION_KEY, 1, 100e6, 200e6, 50e6);
    }
    
    function test_getMultiPoolPositionState() public {
        MultiPoolPositionViewFacet.MultiPoolPositionState memory state = 
            harness.getMultiPoolPositionState(TOKEN_ID);
        
        assertEq(state.tokenId, TOKEN_ID);
        assertEq(state.positionKey, POSITION_KEY);
        assertEq(state.pools.length, 2);
        
        // Check pool 1 data
        assertEq(state.pools[0].poolId, 1);
        assertEq(state.pools[0].underlying, USDC);
        assertEq(state.pools[0].principal, 1000e6);
        assertTrue(state.pools[0].isMember);
        
        // Check pool 2 data
        assertEq(state.pools[1].poolId, 2);
        assertEq(state.pools[1].underlying, USDT);
        assertEq(state.pools[1].principal, 500e6);
        assertTrue(state.pools[1].isMember);
        
        // Check direct agreement summary
        assertEq(state.directState.totalLocked, 100e6);
        assertEq(state.directState.totalLent, 200e6);
        assertEq(state.directState.totalBorrowed, 50e6);
        assertEq(state.directState.activeAgreementCount, 2);
    }
    
    function test_getPositionPoolMemberships() public {
        MultiPoolPositionViewFacet.PoolMembershipInfo[] memory memberships = 
            harness.getPositionPoolMemberships(TOKEN_ID);
        
        assertEq(memberships.length, 2);
        
        // Check pool 1 membership
        assertEq(memberships[0].poolId, 1);
        assertEq(memberships[0].underlying, USDC);
        assertTrue(memberships[0].isMember);
        assertTrue(memberships[0].hasBalance);
        
        // Check pool 2 membership
        assertEq(memberships[1].poolId, 2);
        assertEq(memberships[1].underlying, USDT);
        assertTrue(memberships[1].isMember);
        assertTrue(memberships[1].hasBalance);
    }
    
    function test_getPositionPoolData() public {
        MultiPoolPositionViewFacet.PoolPositionData memory poolData = 
            harness.getPositionPoolData(TOKEN_ID, 1);
        
        assertEq(poolData.poolId, 1);
        assertEq(poolData.underlying, USDC);
        assertEq(poolData.principal, 1000e6);
        assertTrue(poolData.isMember);
        assertFalse(poolData.hasActiveLoan); // No loans set up in this test
    }
    
    function test_isPositionMemberOfPool() public {
        assertTrue(harness.isPositionMemberOfPool(TOKEN_ID, 1));
        assertTrue(harness.isPositionMemberOfPool(TOKEN_ID, 2));
    }
    
    function test_getPositionAggregatedSummary() public {
        (
            uint256 totalPrincipal,
            uint256 totalYield,
            uint256 totalDebt,
            uint256 poolCount,
            MultiPoolPositionViewFacet.DirectAgreementSummary memory directSummary
        ) = harness.getPositionAggregatedSummary(TOKEN_ID);
        
        assertEq(totalPrincipal, 1500e6); // 1000 + 500
        assertEq(totalYield, 0); // No yield accrued in this test
        assertEq(totalDebt, 50e6); // Direct borrowed only
        assertEq(poolCount, 2);
        
        assertEq(directSummary.totalLocked, 100e6);
        assertEq(directSummary.totalLent, 200e6);
        assertEq(directSummary.totalBorrowed, 50e6);
        assertEq(directSummary.activeAgreementCount, 2);
    }
    
    function test_getPositionActivePools() public {
        uint256[] memory activePools = harness.getPositionActivePools(TOKEN_ID);
        
        assertEq(activePools.length, 2);
        assertEq(activePools[0], 1);
        assertEq(activePools[1], 2);
    }
    
    function test_getPositionDirectSummary() public {
        MultiPoolPositionViewFacet.DirectAgreementSummary memory directSummary = 
            harness.getPositionDirectSummary(TOKEN_ID);
        
        assertEq(directSummary.totalLocked, 100e6);
        assertEq(directSummary.totalLent, 200e6);
        assertEq(directSummary.totalBorrowed, 50e6);
        assertEq(directSummary.activeAgreementCount, 2);
    }
    
    function test_selectors() public {
        bytes4[] memory selectors = harness.selectors();
        assertEq(selectors.length, 14);
        
        // Verify some key selectors
        assertEq(selectors[0], MultiPoolPositionViewFacet.getMultiPoolPositionState.selector);
        assertEq(selectors[1], MultiPoolPositionViewFacet.getPositionPoolMemberships.selector);
        assertEq(selectors[2], MultiPoolPositionViewFacet.getPositionPoolData.selector);
    }
}

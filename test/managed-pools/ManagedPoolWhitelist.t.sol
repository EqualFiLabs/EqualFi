// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {NotPoolManager} from "../../src/libraries/Errors.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolWhitelistHarness is PoolManagementFacet {
    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function positionKey(uint256 tokenId) external view returns (bytes32) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
    }

    function setUserPrincipal(uint256 pid, uint256 tokenId, uint256 amount) external {
        bytes32 key = PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
        LibAppStorage.s().pools[pid].userPrincipal[key] = amount;
    }

    function isWhitelisted(uint256 pid, uint256 tokenId) external view returns (bool) {
        bytes32 key = PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
        return LibAppStorage.s().pools[pid].whitelist[key];
    }

    function whitelistFlag(uint256 pid) external view returns (bool poolFlag, bool configFlag) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.whitelistEnabled, p.managedConfig.whitelistEnabled);
    }

    function poolUnderlying(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].underlying;
    }

    function userPrincipal(uint256 pid, uint256 tokenId) external view returns (uint256) {
        bytes32 key = PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
        return LibAppStorage.s().pools[pid].userPrincipal[key];
    }
}

/// **Feature: managed-pools, Property 5: Whitelist management and events**
/// **Validates: Requirements 3.2, 3.4, 3.5, 3.6, 3.7**
contract ManagedPoolWhitelistPropertyTest is Test {
    ManagedPoolWhitelistHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xBEEF);
    address internal manager = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal another = address(0xC0DE);
    PositionNFT internal nft;
    uint256 internal managerTokenId;
    uint256 internal userTokenId;
    uint256 internal anotherTokenId;

    function setUp() public {
        facet = new ManagedPoolWhitelistHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        facet.setManagedPoolCreationFee(0.05 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));

        Types.ManagedPoolConfig memory cfg;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.isCapped = false;
        cfg.manager = manager;
        cfg.whitelistEnabled = true;

        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.05 ether}(1, address(underlying), cfg);
        managerTokenId = nft.mint(manager, 1);
        userTokenId = nft.mint(user, 1);
        anotherTokenId = nft.mint(another, 1);
    }

    function testProperty_WhitelistManagementAndEvents() public {
        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.WhitelistUpdated(1, facet.positionKey(userTokenId), true);
        vm.prank(manager);
        facet.addToWhitelist(1, userTokenId);
        assertTrue(facet.isWhitelisted(1, userTokenId), "user whitelisted");

        vm.expectEmit(true, false, false, true);
        emit PoolManagementFacet.WhitelistToggled(1, false);
        vm.prank(manager);
        facet.setWhitelistEnabled(1, false);
        (bool poolFlag, bool configFlag) = facet.whitelistFlag(1);
        assertFalse(poolFlag, "pool flag off");
        assertFalse(configFlag, "config flag off");

        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, another, manager));
        vm.prank(another);
        facet.addToWhitelist(1, anotherTokenId);

        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.WhitelistUpdated(1, facet.positionKey(userTokenId), false);
        vm.prank(manager);
        facet.removeFromWhitelist(1, userTokenId);
        assertFalse(facet.isWhitelisted(1, userTokenId), "user removed");
    }
}

/// **Feature: managed-pools, Property 6: Removed user operation restrictions**
/// **Validates: Requirements 3.3, 3.8**
contract ManagedPoolWhitelistRemovalPropertyTest is Test {
    ManagedPoolWhitelistHarness internal facet;
    MockERC20 internal underlying;
    address internal treasury = address(0xCAFE);
    address internal manager = address(0xA11CE);
    address internal user = address(0xB0B);
    PositionNFT internal nft;

    function setUp() public {
        facet = new ManagedPoolWhitelistHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        facet.setManagedPoolCreationFee(0.02 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
    }

    function testProperty_RemovedUserOperationsPreserved() public {
        Types.ManagedPoolConfig memory cfg;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.isCapped = false;
        cfg.manager = manager;
        cfg.whitelistEnabled = true;

        vm.deal(manager, 1 ether);
        vm.prank(manager);
        facet.initManagedPool{value: 0.02 ether}(2, address(underlying), cfg);

        assertEq(facet.poolUnderlying(2), address(underlying), "pool initialized");
        uint256 tokenId = nft.mint(user, 2);
        facet.setUserPrincipal(2, tokenId, 10 ether);
        uint256 beforePrincipal = facet.userPrincipal(2, tokenId);
        assertEq(beforePrincipal, 10 ether, "user ledger seeded");

        vm.prank(manager);
        facet.removeFromWhitelist(2, tokenId);

        uint256 principal = facet.userPrincipal(2, tokenId);
        assertEq(principal, 10 ether, "user ledger preserved after removal");
        assertFalse(facet.isWhitelisted(2, tokenId), "user removed");
    }
}

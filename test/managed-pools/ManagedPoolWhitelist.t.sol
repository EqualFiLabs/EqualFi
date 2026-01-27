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

    function setDefaultPoolConfig(Types.PoolConfig memory config) external {
        Types.PoolConfig storage target = LibAppStorage.s().defaultPoolConfig;
        target.rollingApyBps = config.rollingApyBps;
        target.depositorLTVBps = config.depositorLTVBps;
        target.maintenanceRateBps = config.maintenanceRateBps;
        target.flashLoanFeeBps = config.flashLoanFeeBps;
        target.flashLoanAntiSplit = config.flashLoanAntiSplit;
        target.minDepositAmount = config.minDepositAmount;
        target.minLoanAmount = config.minLoanAmount;
        target.minTopupAmount = config.minTopupAmount;
        target.isCapped = config.isCapped;
        target.depositCap = config.depositCap;
        target.maxUserCount = config.maxUserCount;
        target.aumFeeMinBps = config.aumFeeMinBps;
        target.aumFeeMaxBps = config.aumFeeMaxBps;
        target.borrowFee = config.borrowFee;
        target.repayFee = config.repayFee;
        target.withdrawFee = config.withdrawFee;
        target.flashFee = config.flashFee;
        target.closeRollingFee = config.closeRollingFee;
        delete target.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        LibAppStorage.s().defaultPoolConfigSet = true;
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
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolWhitelistHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        facet.setManagedPoolCreationFee(0.05 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_defaultPoolConfig());

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
        facet.initManagedPool{value: 0.05 ether}(MANAGED_PID, address(underlying), cfg);
        managerTokenId = nft.mint(manager, MANAGED_PID);
        userTokenId = nft.mint(user, MANAGED_PID);
        anotherTokenId = nft.mint(another, MANAGED_PID);
    }

    function testProperty_WhitelistManagementAndEvents() public {
        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.WhitelistUpdated(MANAGED_PID, facet.positionKey(userTokenId), true);
        vm.prank(manager);
        facet.addToWhitelist(MANAGED_PID, userTokenId);
        assertTrue(facet.isWhitelisted(MANAGED_PID, userTokenId), "user whitelisted");

        vm.expectEmit(true, false, false, true);
        emit PoolManagementFacet.WhitelistToggled(MANAGED_PID, false);
        vm.prank(manager);
        facet.setWhitelistEnabled(MANAGED_PID, false);
        (bool poolFlag, bool configFlag) = facet.whitelistFlag(MANAGED_PID);
        assertFalse(poolFlag, "pool flag off");
        assertFalse(configFlag, "config flag off");

        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, another, manager));
        vm.prank(another);
        facet.addToWhitelist(MANAGED_PID, anotherTokenId);

        vm.expectEmit(true, true, true, true);
        emit PoolManagementFacet.WhitelistUpdated(MANAGED_PID, facet.positionKey(userTokenId), false);
        vm.prank(manager);
        facet.removeFromWhitelist(MANAGED_PID, userTokenId);
        assertFalse(facet.isWhitelisted(MANAGED_PID, userTokenId), "user removed");
    }

    function _defaultPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
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
    uint256 internal constant MANAGED_PID = 2;

    function setUp() public {
        facet = new ManagedPoolWhitelistHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        facet.setManagedPoolCreationFee(0.02 ether);
        facet.setTreasury(treasury);
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_defaultPoolConfig());
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
        facet.initManagedPool{value: 0.02 ether}(MANAGED_PID, address(underlying), cfg);

        assertEq(facet.poolUnderlying(MANAGED_PID), address(underlying), "pool initialized");
        uint256 tokenId = nft.mint(user, MANAGED_PID);
        facet.setUserPrincipal(MANAGED_PID, tokenId, 10 ether);
        uint256 beforePrincipal = facet.userPrincipal(MANAGED_PID, tokenId);
        assertEq(beforePrincipal, 10 ether, "user ledger seeded");

        vm.prank(manager);
        facet.removeFromWhitelist(MANAGED_PID, tokenId);

        uint256 principal = facet.userPrincipal(MANAGED_PID, tokenId);
        assertEq(principal, 10 ether, "user ledger preserved after removal");
        assertFalse(facet.isWhitelisted(MANAGED_PID, tokenId), "user removed");
    }

    function _defaultPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PoolNotManaged} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract ManagedPoolViewHarness is PoolManagementFacet, ConfigViewFacet {
    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().poolCreationFee = fee;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setDefaultPoolConfig(
        uint16 rollingApyBps,
        uint16 depositorLTVBps,
        uint16 maintenanceRateBps,
        uint16 flashLoanFeeBps,
        bool flashLoanAntiSplit,
        uint256 minDepositAmount,
        uint256 minLoanAmount,
        uint256 minTopupAmount,
        bool isCapped,
        uint256 depositCap,
        uint256 maxUserCount,
        uint16 aumFeeMinBps,
        uint16 aumFeeMaxBps
    ) external {
        Types.PoolConfig storage target = LibAppStorage.s().defaultPoolConfig;
        target.rollingApyBps = rollingApyBps;
        target.depositorLTVBps = depositorLTVBps;
        target.maintenanceRateBps = maintenanceRateBps;
        target.flashLoanFeeBps = flashLoanFeeBps;
        target.flashLoanAntiSplit = flashLoanAntiSplit;
        target.minDepositAmount = minDepositAmount;
        target.minLoanAmount = minLoanAmount;
        target.minTopupAmount = minTopupAmount;
        target.isCapped = isCapped;
        target.depositCap = depositCap;
        target.maxUserCount = maxUserCount;
        target.aumFeeMinBps = aumFeeMinBps;
        target.aumFeeMaxBps = aumFeeMaxBps;
        delete target.fixedTermConfigs;
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function _positionKeyForToken(uint256 pid, uint256 tokenId)
        internal
        view
        override(PoolManagementFacet, ConfigViewFacet)
        returns (bytes32)
    {
        return PoolManagementFacet._positionKeyForToken(pid, tokenId);
    }
}

/// **Feature: managed-pools, view functions**
/// **Validates: Requirements 7.1, 7.2, 7.3, 7.4, 7.5**
contract ManagedPoolViewsTest is Test {
    ManagedPoolViewHarness internal harness;
    MockERC20 internal underlying;
    address internal treasury = address(0xFEED);
    address internal manager = address(0xBEEF);
    address internal other = address(0xCAFE);
    PositionNFT internal nft;
    uint256 internal unmanagedTokenId;
    uint256 internal managedManagerTokenId;
    uint256 internal managedOtherTokenId;

    function setUp() public {
        harness = new ManagedPoolViewHarness();
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));
        harness.setTreasury(treasury);
        harness.setOwner(address(this));
        harness.setPoolCreationFee(0.05 ether);
        harness.setManagedPoolCreationFee(0.1 ether);
    }

    function _managedConfig() internal pure returns (Types.ManagedPoolConfig memory cfg) {
        Types.ActionFeeSet memory actionFees;
        cfg = Types.ManagedPoolConfig({
            rollingApyBps: 500,
            depositorLTVBps: 8000,
            maintenanceRateBps: 50,
            flashLoanFeeBps: 10,
            flashLoanAntiSplit: false,
            minDepositAmount: 1 ether,
            minLoanAmount: 1 ether,
            minTopupAmount: 0.1 ether,
            isCapped: false,
            depositCap: 0,
            maxUserCount: 0,
            aumFeeMinBps: 100,
            aumFeeMaxBps: 500,
            fixedTermConfigs: new Types.FixedTermConfig[](0),
            actionFees: actionFees,
            manager: address(0),
            whitelistEnabled: true
        });
    }

    function _initUnmanagedPool() internal returns (uint256 pid) {
        harness.setDefaultPoolConfig(
            500,
            8000,
            50,
            10,
            false,
            1 ether,
            1 ether,
            0.1 ether,
            false,
            0,
            0,
            100,
            500
        );
        vm.deal(other, 1 ether);
        vm.prank(other);
        pid = harness.initPool{value: 0.05 ether}(address(underlying));
        unmanagedTokenId = nft.mint(other, 1);
    }

    function _assertUnmanagedPoolViews(uint256 pid) internal {
        assertFalse(harness.isManagedPool(pid), "unmanaged flag");
        assertEq(harness.getPoolManager(pid), address(0), "unmanaged manager zero");
        assertFalse(harness.isWhitelistEnabled(pid), "unmanaged whitelist disabled");
        assertTrue(harness.isWhitelisted(pid, unmanagedTokenId), "unmanaged always whitelisted");
        vm.expectRevert(abi.encodeWithSelector(PoolNotManaged.selector, pid));
        harness.getManagedPoolConfig(pid);
    }

    function _initManagedPool() internal returns (uint256 pid) {
        Types.ManagedPoolConfig memory mCfg = _managedConfig();
        mCfg.manager = manager;
        vm.deal(manager, 1 ether);
        vm.prank(manager);
        pid = 2;
        harness.initManagedPool{value: 0.1 ether}(pid, address(underlying), mCfg);
        managedManagerTokenId = nft.mint(manager, pid);
        managedOtherTokenId = nft.mint(other, pid);
        vm.prank(manager);
        harness.addToWhitelist(pid, managedManagerTokenId);
    }

    function _assertManagedPoolViews(uint256 pid) internal {
        assertTrue(harness.isManagedPool(pid), "managed flag");
        assertEq(harness.getPoolManager(pid), manager, "manager exposed");
        assertTrue(harness.isWhitelistEnabled(pid), "whitelist enabled");
        assertTrue(harness.isWhitelisted(pid, managedManagerTokenId), "manager token whitelisted");
        assertFalse(harness.isWhitelisted(pid, managedOtherTokenId), "non-whitelisted false");

        // Update managed config and verify view reflects current values
        vm.prank(manager);
        harness.setRollingApy(pid, 750);
        Types.ManagedPoolConfig memory cfgView = harness.getManagedPoolConfig(pid);
        assertEq(cfgView.rollingApyBps, 750, "managed config updated");
    }

    function testViewFunctionsManagedAndUnmanaged() public {
        uint256 unmanagedPid = _initUnmanagedPool();
        _assertUnmanagedPoolViews(unmanagedPid);

        uint256 managedPid = _initManagedPool();
        _assertManagedPoolViews(managedPid);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "../../src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {
    PositionAgent_ConfigLocked,
    PositionAgent_InvalidConfigAddress,
    PositionAgent_NotAdmin
} from "../../src/libraries/PositionAgentErrors.sol";
import {BeaconProxy} from "@agent-wallet-core/core/BeaconProxy.sol";
import {MockBeacon} from "../helpers/MockBeacon.sol";

contract PositionAgentConfigFacetHarness is PositionAgentConfigFacet {
    function getConfig()
        external
        view
        returns (address erc6551Registry, address erc6551Implementation, address identityRegistry)
    {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        return (ds.erc6551Registry, ds.erc6551Implementation, ds.identityRegistry);
    }
}

contract MockERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account) {
        assembly {
            pop(chainId)
            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            let computed := keccak256(0x00, 0x55)

            if iszero(extcodesize(computed)) {
                let deployed := create2(0, 0x55, 0xb7, salt)
                if iszero(deployed) {
                    mstore(0x00, 0x20188a59)
                    revert(0x1c, 0x04)
                }
                mstore(0x6c, deployed)
                return(0x6c, 0x20)
            }

            mstore(0x00, shr(96, shl(96, computed)))
            return(0x00, 0x20)
        }
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account) {
        assembly {
            pop(chainId)
            pop(tokenContract)
            pop(tokenId)

            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            mstore(0x00, shr(96, shl(96, keccak256(0x00, 0x55))))
            return(0x00, 0x20)
        }
    }
}

contract MockERC6551Account {
    receive() external payable {}
}

contract MockIdentityRegistry {
    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }
}

contract PositionAgentConfigLockHarness is PositionAgentConfigFacet, PositionAgentTBAFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function getConfigLocked() external view returns (bool) {
        return LibPositionAgentStorage.s().tbaConfigLocked;
    }
}

/// @notice Property-based tests for configuration management
/// forge-config: default.fuzz.runs = 100
contract PositionAgentConfigPropertyTest is Test {
    PositionAgentConfigFacetHarness private facet;
    address private owner = address(0xA11CE);
    address private attacker = address(0xBEEF);

    bytes32 private constant DIAMOND_SLOT = keccak256("diamond.standard.diamond.storage");
    bytes private constant MIN_RUNTIME = hex"00";

    function setUp() public {
        facet = new PositionAgentConfigFacetHarness();
        uint256 ownerSlot = uint256(DIAMOND_SLOT) + 3;
        vm.store(address(facet), bytes32(ownerSlot), bytes32(uint256(uint160(owner))));
    }

    /// @notice **Feature: erc6551-position-agents, Property 9: Configuration Management**
    /// @notice Admin can set registry addresses; non-admin cannot
    /// @notice **Validates: Requirements 9.1, 9.2, 9.3, 9.5**
    function testProperty_ConfigurationManagement(address reg, address impl, address id) public {
        _assumeWritableAddress(reg);
        _assumeWritableAddress(impl);
        _assumeWritableAddress(id);
        vm.etch(reg, MIN_RUNTIME);
        vm.etch(impl, MIN_RUNTIME);
        vm.etch(id, MIN_RUNTIME);

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit PositionAgentConfigFacet.ERC6551RegistryUpdated(address(0), reg);
        facet.setERC6551Registry(reg);

        vm.expectEmit(true, true, false, true);
        emit PositionAgentConfigFacet.ERC6551ImplementationUpdated(address(0), impl);
        facet.setERC6551Implementation(impl);

        vm.expectEmit(true, true, false, true);
        emit PositionAgentConfigFacet.IdentityRegistryUpdated(address(0), id);
        facet.setIdentityRegistry(id);
        vm.stopPrank();

        (address gotReg, address gotImpl, address gotId) = facet.getConfig();
        assertEq(gotReg, reg, "erc6551Registry should update");
        assertEq(gotImpl, impl, "erc6551Implementation should update");
        assertEq(gotId, id, "identityRegistry should update");

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_NotAdmin.selector, attacker));
        facet.setERC6551Registry(address(0x1234));
        vm.stopPrank();
    }

    function test_configSetters_revertForZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, address(0)));
        facet.setERC6551Registry(address(0));
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, address(0)));
        facet.setERC6551Implementation(address(0));
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, address(0)));
        facet.setIdentityRegistry(address(0));
        vm.stopPrank();
    }

    function test_configSetters_revertForNonContract() public {
        address eoa = address(0x1234);
        assertEq(eoa.code.length, 0, "test precondition: EOA has no bytecode");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, eoa));
        facet.setERC6551Registry(eoa);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, eoa));
        facet.setERC6551Implementation(eoa);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, eoa));
        facet.setIdentityRegistry(eoa);
        vm.stopPrank();
    }

    function _assumeWritableAddress(address candidate) internal {
        vm.assume(candidate != address(0));
        vm.assume(candidate != address(facet));
        vm.assume(candidate != owner);
        vm.assume(candidate != attacker);
        // Avoid low-address reserved space (precompiles/system contracts) where vm.etch is disallowed.
        vm.assume(uint160(candidate) > 0xFFFF);
    }
}

contract PositionAgentConfigLockPropertyTest is Test {
    PositionAgentConfigLockHarness private facet;
    PositionNFT private nft;
    MockERC6551Registry private registry;
    MockERC6551Account private implementation;
    MockBeacon private beacon;
    BeaconProxy private beaconProxy;
    MockIdentityRegistry private identity;

    address private owner = address(0xA11CE);

    bytes32 private constant DIAMOND_SLOT = keccak256("diamond.standard.diamond.storage");

    function setUp() public {
        facet = new PositionAgentConfigLockHarness();
        uint256 ownerSlot = uint256(DIAMOND_SLOT) + 3;
        vm.store(address(facet), bytes32(ownerSlot), bytes32(uint256(uint160(owner))));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        registry = new MockERC6551Registry();
        implementation = new MockERC6551Account();
        beacon = new MockBeacon(address(implementation));
        beaconProxy = new BeaconProxy(address(beacon));
        identity = new MockIdentityRegistry();

        facet.setPositionNFT(address(nft));

        vm.startPrank(owner);
        facet.setERC6551Registry(address(registry));
        facet.setERC6551Implementation(address(beaconProxy));
        facet.setIdentityRegistry(address(identity));
        vm.stopPrank();
    }

    function test_configSetters_revertAfterFirstTBADeployment() public {
        uint256 tokenId = nft.mint(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);
        assertGt(tba.code.length, 0, "TBA should be deployed");
        assertTrue(facet.getConfigLocked(), "config should lock after first deployment");

        MockERC6551Registry registryB = new MockERC6551Registry();
        MockERC6551Account implementationB = new MockERC6551Account();
        MockBeacon beaconB = new MockBeacon(address(implementationB));
        BeaconProxy beaconProxyB = new BeaconProxy(address(beaconB));
        MockIdentityRegistry identityB = new MockIdentityRegistry();

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_ConfigLocked.selector));
        facet.setERC6551Registry(address(registryB));
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_ConfigLocked.selector));
        facet.setERC6551Implementation(address(beaconProxyB));
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_ConfigLocked.selector));
        facet.setIdentityRegistry(address(identityB));
        vm.stopPrank();
    }
}

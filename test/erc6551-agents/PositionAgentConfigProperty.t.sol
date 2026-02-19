// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgent_InvalidConfigAddress, PositionAgent_NotAdmin} from "../../src/libraries/PositionAgentErrors.sol";

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

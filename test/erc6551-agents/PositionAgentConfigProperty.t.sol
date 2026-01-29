// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPositionAgentStorage} from "../../src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentConfigFacet} from "../../src/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgent_NotAdmin} from "../../src/libraries/PositionAgentErrors.sol";

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

    function setUp() public {
        facet = new PositionAgentConfigFacetHarness();
        uint256 ownerSlot = uint256(DIAMOND_SLOT) + 3;
        vm.store(address(facet), bytes32(ownerSlot), bytes32(uint256(uint160(owner))));
    }

    /// @notice **Feature: erc6551-position-agents, Property 9: Configuration Management**
    /// @notice Admin can set registry addresses; non-admin cannot
    /// @notice **Validates: Requirements 9.1, 9.2, 9.3, 9.5**
    function testProperty_ConfigurationManagement(address reg, address impl, address id) public {
        vm.assume(reg != address(0));
        vm.assume(impl != address(0));
        vm.assume(id != address(0));

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
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {AdminFacet} from "../../src/admin/AdminFacet.sol";

contract AdminFacetTest is Test {
    event TimelockUpdated(address indexed previous, address indexed current);

    Diamond internal diamond;
    AdminFacet internal adminFacet;

    address internal constant OWNER = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xBEEF);

    function setUp() public {
        adminFacet = new AdminFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(adminFacet), _selectors(adminFacet));

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: OWNER}));
    }

    function test_setTimelock_onlyOwner() public {
        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("LibDiamond: must be owner"));
        AdminFacet(address(diamond)).setTimelock(address(0x1234));
    }

    function test_setTimelock_updatesStorageAndEmitsEvent() public {
        address newTimelock = address(0x1234);

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit TimelockUpdated(address(0), newTimelock);
        AdminFacet(address(diamond)).setTimelock(newTimelock);

        assertEq(AdminFacet(address(diamond)).timelock(), newTimelock);
    }

    function test_setTimelock_allowsZeroAddress() public {
        vm.startPrank(OWNER);
        AdminFacet(address(diamond)).setTimelock(address(0x1234));
        AdminFacet(address(diamond)).setTimelock(address(0));
        vm.stopPrank();

        assertEq(AdminFacet(address(diamond)).timelock(), address(0));
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectors(AdminFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.setTimelock.selector;
        s[1] = AdminFacet.timelock.selector;
    }
}


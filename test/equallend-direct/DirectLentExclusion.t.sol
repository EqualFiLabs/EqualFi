// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

interface IPositionManagement {
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external returns (uint256);
}

contract DirectLentExclusionTest is DirectDiamondTestBase {
    IPositionManagement internal pm;
    MockERC20 internal token;

    address internal user = address(0xA11CE);
    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        setUpDiamond();
        _addPositionManagementFacet();
        pm = IPositionManagement(address(diamond));
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        finalizePositionNFT();

        harness.initPool(PID, address(token), 1, 1, LTV_BPS);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_directLentPrincipalNotCountedAsDebt() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPositionWithDeposit(PID, 100 ether);
        bytes32 key = nft.getPositionKey(tokenId);
        vm.stopPrank();

        // Simulate a direct lend exposure; lender principal is already debited in real flows.
        harness.setDirectState(key, PID, 0, 60 ether, 0);

        uint256 debt = views.getTotalDebt(PID, key);
        assertEq(debt, 0, "direct lending should not raise debt");
    }

    function _addPositionManagementFacet() internal {
        PositionManagementFacet pmFacet = new PositionManagementFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(address(pmFacet), _selectorsPositionManagement());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
    }
}

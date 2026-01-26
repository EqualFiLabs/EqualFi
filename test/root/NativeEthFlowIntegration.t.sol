// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondInit} from "../../src/core/DiamondInit.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

interface IPoolManagementFacet {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

contract NativePoolViewFacet {
    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function userPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[key];
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }
}

contract NativeEthFlowIntegrationTest is Test {
    Diamond internal diamond;
    PositionNFT internal nft;

    IPoolManagementFacet internal poolFacet;
    PositionManagementFacet internal positionFacet;
    LendingFacet internal lendingFacet;
    NativePoolViewFacet internal viewFacet;

    uint256 internal constant PID = 1;
    address internal user = address(0xA11CE);

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        PoolManagementFacet pool = new PoolManagementFacet();
        PositionManagementFacet position = new PositionManagementFacet();
        LendingFacet lending = new LendingFacet();
        NativePoolViewFacet viewFacetImpl = new NativePoolViewFacet();
        DiamondInit initializer = new DiamondInit();
        nft = new PositionNFT();

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](4);
        addCuts[0] = _cut(address(pool), _selectorsPool());
        addCuts[1] = _cut(address(position), _selectorsPosition());
        addCuts[2] = _cut(address(lending), _selectorsLending());
        addCuts[3] = _cut(address(viewFacetImpl), _selectorsView());

        IDiamondCut(address(diamond)).diamondCut(
            addCuts,
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, address(0xBEEF), address(nft))
        );

        poolFacet = IPoolManagementFacet(address(diamond));
        positionFacet = PositionManagementFacet(address(diamond));
        lendingFacet = LendingFacet(address(diamond));
        viewFacet = NativePoolViewFacet(address(diamond));
    }

    /// Feature: native-eth-support, Integration 13.1: Native pool lifecycle
    function testIntegration_NativePoolDepositBorrowRepayWithdraw() public {
        Types.PoolConfig memory config = _defaultConfig();
        poolFacet.initPool(PID, address(0), config);

        uint256 depositAmount = 10 ether;
        uint256 borrowAmount = 4 ether;
        uint256 funding = depositAmount + borrowAmount + 1 ether;
        vm.deal(address(diamond), funding);

        vm.prank(user);
        uint256 tokenId = positionFacet.mintPositionWithDeposit(PID, depositAmount);
        bytes32 key = nft.getPositionKey(tokenId);

        assertEq(viewFacet.trackedBalance(PID), depositAmount, "tracked after deposit");
        assertEq(viewFacet.totalDeposits(PID), depositAmount, "deposits after deposit");
        assertEq(viewFacet.nativeTrackedTotal(), depositAmount, "native tracked after deposit");

        uint256 userBalanceBefore = user.balance;
        vm.prank(user);
        lendingFacet.openRollingFromPosition(tokenId, PID, borrowAmount);

        assertEq(user.balance - userBalanceBefore, borrowAmount, "user received borrow");
        assertEq(viewFacet.trackedBalance(PID), depositAmount - borrowAmount, "tracked after borrow");
        assertEq(viewFacet.nativeTrackedTotal(), depositAmount - borrowAmount, "native tracked after borrow");

        vm.prank(user);
        lendingFacet.makePaymentFromPosition(tokenId, PID, borrowAmount);

        assertEq(viewFacet.trackedBalance(PID), depositAmount, "tracked after repay");
        assertEq(viewFacet.nativeTrackedTotal(), depositAmount, "native tracked after repay");

        userBalanceBefore = user.balance;
        vm.prank(user);
        positionFacet.withdrawFromPosition(tokenId, PID, depositAmount);

        assertEq(user.balance - userBalanceBefore, depositAmount, "user received withdraw");
        assertEq(viewFacet.trackedBalance(PID), 0, "tracked after withdraw");
        assertEq(viewFacet.totalDeposits(PID), 0, "deposits after withdraw");
        assertEq(viewFacet.userPrincipal(PID, key), 0, "principal cleared");
        assertEq(viewFacet.nativeTrackedTotal(), 0, "native tracked after withdraw");
    }

    function _defaultConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 0;
        cfg.flashLoanFeeBps = 0;
        cfg.rollingApyBps = 0;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 0;
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsPool() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IPoolManagementFacet.initPool.selector;
    }

    function _selectorsPosition() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = PositionManagementFacet.withdrawFromPosition.selector;
    }

    function _selectorsLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = LendingFacet.openRollingFromPosition.selector;
        s[1] = LendingFacet.makePaymentFromPosition.selector;
    }

    function _selectorsView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = NativePoolViewFacet.trackedBalance.selector;
        s[1] = NativePoolViewFacet.totalDeposits.selector;
        s[2] = NativePoolViewFacet.userPrincipal.selector;
        s[3] = NativePoolViewFacet.nativeTrackedTotal.selector;
    }
}

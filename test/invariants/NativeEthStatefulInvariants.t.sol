// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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

contract NativeEthInvariantView {
    function trackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function userPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[key];
    }

    function rollingPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].rollingLoans[key].principalRemaining;
    }

    function rollingActive(uint256 pid, bytes32 key) external view returns (bool) {
        return LibAppStorage.s().pools[pid].rollingLoans[key].active;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }
}

contract NativeEthStatefulHandler is Test {
    PositionManagementFacet internal position;
    LendingFacet internal lending;
    NativeEthInvariantView internal viewFacet;
    address internal pool;

    address internal user;
    uint256 internal pid;
    uint256 internal tokenId;
    bytes32 internal positionKey;
    uint16 internal ltvBps;

    constructor(
        PositionManagementFacet position_,
        LendingFacet lending_,
        NativeEthInvariantView view_,
        address pool_,
        address user_,
        uint256 pid_,
        uint256 tokenId_,
        bytes32 positionKey_,
        uint16 ltvBps_
    ) {
        position = position_;
        lending = lending_;
        viewFacet = view_;
        pool = pool_;
        user = user_;
        pid = pid_;
        tokenId = tokenId_;
        positionKey = positionKey_;
        ltvBps = ltvBps_;
    }

    function fundPool(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1 ether, 50 ether);
        uint256 newBalance = pool.balance + amount;
        vm.deal(pool, newBalance);
    }

    function deposit(uint256 amountSeed) external {
        uint256 available = _nativeAvailable();
        if (available == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(user);
        position.depositToPosition(tokenId, pid, amount);
    }

    function withdraw(uint256 amountSeed) external {
        uint256 debt = viewFacet.rollingPrincipal(pid, positionKey);
        if (debt > 0) {
            return;
        }
        uint256 principal = viewFacet.userPrincipal(pid, positionKey);
        if (principal == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, principal);
        vm.prank(user);
        position.withdrawFromPosition(tokenId, pid, amount);
    }

    function borrow(uint256 amountSeed) external {
        uint256 debt = viewFacet.rollingPrincipal(pid, positionKey);
        if (debt > 0) {
            return;
        }
        uint256 principal = viewFacet.userPrincipal(pid, positionKey);
        if (principal == 0) {
            return;
        }
        uint256 maxBorrow = (principal * ltvBps) / 10_000;
        uint256 tracked = viewFacet.trackedBalance(pid);
        uint256 capacity = tracked < maxBorrow ? tracked : maxBorrow;
        if (capacity == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, capacity);
        vm.prank(user);
        lending.openRollingFromPosition(tokenId, pid, amount);
    }

    function repay(uint256 amountSeed) external {
        uint256 debt = viewFacet.rollingPrincipal(pid, positionKey);
        if (debt == 0) {
            return;
        }
        uint256 available = _nativeAvailable();
        if (available == 0) {
            return;
        }
        uint256 maxPay = debt < available ? debt : available;
        if (maxPay == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, maxPay);
        vm.prank(user);
        lending.makePaymentFromPosition(tokenId, pid, amount);
    }

    function _nativeAvailable() internal view returns (uint256) {
        uint256 tracked = viewFacet.nativeTrackedTotal();
        uint256 balance = pool.balance;
        if (balance <= tracked) {
            return 0;
        }
        return balance - tracked;
    }
}

contract NativeEthStatefulInvariantTest is StdInvariant, Test {
    Diamond internal diamond;
    PositionNFT internal nft;

    IPoolManagementFacet internal poolFacet;
    PositionManagementFacet internal positionFacet;
    LendingFacet internal lendingFacet;
    NativeEthInvariantView internal viewFacet;

    NativeEthStatefulHandler internal handler;

    address internal user = address(0xA11CE);
    uint256 internal tokenId;
    bytes32 internal positionKey;

    uint256 internal constant PID = 1;
    uint16 internal constant LTV_BPS = 8_000;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        PoolManagementFacet pool = new PoolManagementFacet();
        PositionManagementFacet position = new PositionManagementFacet();
        LendingFacet lending = new LendingFacet();
        NativeEthInvariantView viewFacetImpl = new NativeEthInvariantView();
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
        viewFacet = NativeEthInvariantView(address(diamond));

        Types.PoolConfig memory config = _defaultConfig();
        poolFacet.initPool(PID, address(0), config);

        uint256 initialBalance = 1_000 ether;
        vm.deal(address(diamond), initialBalance);

        uint256 depositAmount = 50 ether;
        vm.prank(user);
        tokenId = positionFacet.mintPositionWithDeposit(PID, depositAmount);
        positionKey = nft.getPositionKey(tokenId);

        handler = new NativeEthStatefulHandler(
            positionFacet,
            lendingFacet,
            viewFacet,
            address(diamond),
            user,
            PID,
            tokenId,
            positionKey,
            LTV_BPS
        );
        targetContract(address(handler));
    }

    function invariant_nativeTrackedWithinBalance() public {
        assertLe(viewFacet.nativeTrackedTotal(), address(diamond).balance);
    }

    function invariant_trackedMatchesNativeTotal() public {
        assertEq(viewFacet.trackedBalance(PID), viewFacet.nativeTrackedTotal());
    }

    function invariant_poolConservation() public {
        uint256 debt = viewFacet.rollingPrincipal(PID, positionKey);
        assertEq(viewFacet.trackedBalance(PID) + debt, viewFacet.totalDeposits(PID));
    }

    function invariant_principalMatchesDeposits() public {
        assertEq(viewFacet.userPrincipal(PID, positionKey), viewFacet.totalDeposits(PID));
    }

    function invariant_inactiveLoanHasZeroPrincipal() public {
        if (!viewFacet.rollingActive(PID, positionKey)) {
            assertEq(viewFacet.rollingPrincipal(PID, positionKey), 0);
        }
    }

    function _defaultConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.depositorLTVBps = LTV_BPS;
        cfg.maintenanceRateBps = 0;
        cfg.flashLoanFeeBps = 0;
        cfg.flashLoanAntiSplit = false;
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
        s = new bytes4[](3);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = PositionManagementFacet.depositToPosition.selector;
        s[2] = PositionManagementFacet.withdrawFromPosition.selector;
    }

    function _selectorsLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = LendingFacet.openRollingFromPosition.selector;
        s[1] = LendingFacet.makePaymentFromPosition.selector;
    }

    function _selectorsView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = NativeEthInvariantView.trackedBalance.selector;
        s[1] = NativeEthInvariantView.totalDeposits.selector;
        s[2] = NativeEthInvariantView.userPrincipal.selector;
        s[3] = NativeEthInvariantView.rollingPrincipal.selector;
        s[4] = NativeEthInvariantView.rollingActive.selector;
        s[5] = NativeEthInvariantView.nativeTrackedTotal.selector;
    }
}

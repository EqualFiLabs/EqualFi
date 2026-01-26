// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {CannotClearMembership} from "../../src/libraries/Errors.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Management facet harness exposing setup helpers for tests (used via diamond)
contract PositionManagementHarnessFacet is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function isMember(bytes32 key, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(key, pid);
    }

    function principalOf(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].userPrincipal[key];
    }

    function rollingOf(uint256 pid, bytes32 key) external view returns (Types.RollingCreditLoan memory) {
        return s().pools[pid].rollingLoans[key];
    }

    function setDirectLocks(bytes32 positionKey, uint256 pid, uint256 locked, uint256 escrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = escrowed;
    }
}

interface IPositionManagementHarness {
    function configurePositionNFT(address nft) external;
    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external;
    function isMember(bytes32 key, uint256 pid) external view returns (bool);
    function mintPosition(uint256 pid) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function closePoolPosition(uint256 tokenId, uint256 pid) external;
    function cleanupMembership(uint256 tokenId, uint256 pid) external;
    function principalOf(uint256 pid, bytes32 key) external view returns (uint256);
    function rollingOf(uint256 pid, bytes32 key) external view returns (Types.RollingCreditLoan memory);
    function setDirectLocks(bytes32 positionKey, uint256 pid, uint256 locked, uint256 escrowed) external;
}

interface ILendingFacetHarness {
    function openRollingFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function makePaymentFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function closeRollingCreditFromPosition(uint256 tokenId, uint256 pid) external;
}

contract MultiPoolPositionIntegrationTest is Test {
    Diamond internal diamond;
    PositionNFT internal nft;
    MockERC20 internal token;

    IPositionManagementHarness internal pm;
    ILendingFacetHarness internal lending;

    address internal user = address(0xA11CE);
    uint256 constant PID1 = 1;
    uint256 constant PID2 = 2;

    function setUp() public {
        // Deploy facets
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        PositionManagementHarnessFacet pmFacet = new PositionManagementHarnessFacet();
        LendingFacet lendingFacet = new LendingFacet();

        // Initial cut for core facets
        IDiamondCut.FacetCut[] memory baseCuts = new IDiamondCut.FacetCut[](3);
        baseCuts[0] = _cut(address(cut), _selectors(cut));
        baseCuts[1] = _cut(address(loupe), _selectors(loupe));
        baseCuts[2] = _cut(address(own), _selectors(own));

        diamond = new Diamond(baseCuts, Diamond.DiamondArgs({owner: address(this)}));

        // Add management and lending facets
        IDiamondCut.FacetCut[] memory added = new IDiamondCut.FacetCut[](2);
        added[0] = _cut(address(pmFacet), _selectors(pmFacet));
        added[1] = _cut(address(lendingFacet), _selectors(lendingFacet));
        IDiamondCut(address(diamond)).diamondCut(added, address(0), "");

        // Wire interfaces to the diamond
        pm = IPositionManagementHarness(address(diamond));
        lending = ILendingFacetHarness(address(diamond));

        // Deploy token/NFT and configure pools
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));
        pm.initPool(PID1, address(token), 1, 1, 8_000);
        pm.initPool(PID2, address(token), 1, 1, 8_000);

        // Fund contract and user
        token.mint(address(diamond), 1_000_000 ether);
        token.transfer(user, 500_000 ether);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_multiPoolWorkflowIsolatedAndCleansUpMembership() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(PID1);
        bytes32 key = nft.getPositionKey(tokenId);

        // Deposit into both pools
        pm.depositToPosition(tokenId, PID1, 100 ether);
        pm.depositToPosition(tokenId, PID2, 50 ether);

        // Borrow only in PID1
        lending.openRollingFromPosition(tokenId, PID1, 30 ether);
        vm.stopPrank();

        assertEq(pm.principalOf(PID1, key), 100 ether, "pid1 principal");
        assertEq(pm.principalOf(PID2, key), 50 ether, "pid2 principal");
        assertEq(pm.rollingOf(PID1, key).principalRemaining, 30 ether, "pid1 rolling debt");
        assertEq(pm.rollingOf(PID2, key).principalRemaining, 0, "pid2 no debt");

        // Withdraw and cleanup membership in PID2
        vm.prank(user);
        pm.withdrawFromPosition(tokenId, PID2, 50 ether);
        assertEq(pm.principalOf(PID2, key), 0, "pid2 principal cleared");

        vm.prank(user);
        pm.cleanupMembership(tokenId, PID2);
        assertFalse(pm.isMember(key, PID2), "pid2 membership cleared");
        assertTrue(pm.isMember(key, PID1), "pid1 membership persists");

        // Repay and cleanup PID1
        vm.startPrank(user);
        lending.makePaymentFromPosition(tokenId, PID1, 30 ether);
        pm.withdrawFromPosition(tokenId, PID1, 100 ether);
        pm.cleanupMembership(tokenId, PID1);
        vm.stopPrank();

        assertEq(pm.principalOf(PID1, key), 0, "pid1 principal cleared");
        assertFalse(pm.isMember(key, PID1), "pid1 membership cleared");
    }

    function test_closePoolPositionWithdrawsAllAvailablePrincipal() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(PID1);
        bytes32 key = nft.getPositionKey(tokenId);

        pm.depositToPosition(tokenId, PID1, 100 ether);
        uint256 balanceAfterDeposit = token.balanceOf(user);

        pm.closePoolPosition(tokenId, PID1);
        vm.stopPrank();

        assertEq(pm.principalOf(PID1, key), 0, "principal cleared after close");
        assertEq(token.balanceOf(user), balanceAfterDeposit + 100 ether, "user received full principal back");
        assertFalse(pm.isMember(key, PID1), "membership cleared after close");
    }

    function test_closePoolPositionKeepsMembershipWithDirectCommitments() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(PID1);
        bytes32 key = nft.getPositionKey(tokenId);

        pm.depositToPosition(tokenId, PID1, 100 ether);
        uint256 balanceAfterDeposit = token.balanceOf(user);
        vm.stopPrank();

        pm.setDirectLocks(key, PID1, 30 ether, 10 ether);

        vm.prank(user);
        pm.closePoolPosition(tokenId, PID1);

        assertEq(pm.principalOf(PID1, key), 40 ether, "principal left for commitments");
        assertEq(token.balanceOf(user), balanceAfterDeposit + 60 ether, "user received available principal");
        assertTrue(pm.isMember(key, PID1), "membership retained with commitments");
    }

    function test_closePoolPosition_withCommitments_blocksCleanup() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(PID1);
        bytes32 key = nft.getPositionKey(tokenId);

        pm.depositToPosition(tokenId, PID1, 100 ether);
        vm.stopPrank();

        pm.setDirectLocks(key, PID1, 30 ether, 10 ether);

        vm.prank(user);
        pm.closePoolPosition(tokenId, PID1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CannotClearMembership.selector, key, PID1, "principal>0"));
        pm.cleanupMembership(tokenId, PID1);
    }

    function test_closePoolPosition_cleanupSucceedsAfterCommitmentsCleared() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(PID1);
        bytes32 key = nft.getPositionKey(tokenId);

        pm.depositToPosition(tokenId, PID1, 100 ether);
        vm.stopPrank();

        pm.setDirectLocks(key, PID1, 30 ether, 10 ether);

        vm.prank(user);
        pm.closePoolPosition(tokenId, PID1);

        pm.setDirectLocks(key, PID1, 0, 0);

        vm.prank(user);
        pm.withdrawFromPosition(tokenId, PID1, 40 ether);

        vm.prank(user);
        pm.cleanupMembership(tokenId, PID1);

        assertFalse(pm.isMember(key, PID1), "membership cleared after commitments removed");
    }

    // selector helpers
    function _cut(address facet, bytes4[] memory selectors_) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors_;
    }

    function _selectors(DiamondCutFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectors(DiamondLoupeFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectors(OwnershipFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectors(PositionManagementHarnessFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = PositionManagementHarnessFacet.configurePositionNFT.selector;
        s[1] = PositionManagementHarnessFacet.initPool.selector;
        s[2] = PositionManagementHarnessFacet.isMember.selector;
        s[3] = PositionManagementFacet.mintPosition.selector;
        s[4] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[5] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
        s[6] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256)"));
        s[7] = bytes4(keccak256("closePoolPosition(uint256,uint256)"));
        s[8] = bytes4(keccak256("rollYieldToPosition(uint256,uint256)"));
        s[9] = bytes4(keccak256("cleanupMembership(uint256,uint256)"));
        s[10] = PositionManagementHarnessFacet.principalOf.selector;
        s[11] = PositionManagementHarnessFacet.rollingOf.selector;
        s[12] = PositionManagementHarnessFacet.setDirectLocks.selector;
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256)"));
        s[1] = bytes4(keccak256("makePaymentFromPosition(uint256,uint256,uint256)"));
        s[2] = bytes4(keccak256("expandRollingFromPosition(uint256,uint256,uint256)"));
        s[3] = bytes4(keccak256("closeRollingCreditFromPosition(uint256,uint256)"));
        s[4] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256)"));
        s[5] = bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256,uint256)"));
    }
}

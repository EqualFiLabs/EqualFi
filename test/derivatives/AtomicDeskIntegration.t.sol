// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {AtomicDeskFacet} from "../../src/EqualX/AtomicDeskFacet.sol";
import {SettlementEscrowFacet} from "../../src/EqualX/SettlementEscrowFacet.sol";
import {Mailbox} from "../../src/EqualX/Mailbox.sol";
import {AtomicTypes} from "../../src/libraries/AtomicTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

interface IAtomicDeskTestHarness {
    function setPositionNFT(address nft) external;
    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked) external;
    function joinPool(bytes32 positionKey, uint256 pid) external;
    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function getPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getTracked(uint256 pid) external view returns (uint256);
    function setTreasury(address treasury) external;
}

contract AtomicDeskTestHarnessFacet {
    function setPositionNFT(address nftAddr) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nftAddr;
        ns.nftModeEnabled = true;
    }

    function seedPool(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getTracked(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }
}

abstract contract AtomicDeskDiamondTestBase is Test {
    Diamond internal diamond;
    IAtomicDeskTestHarness internal harness;
    AtomicDeskFacet internal atomicDesk;
    SettlementEscrowFacet internal escrow;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Mailbox internal mailbox;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal committee = address(0xC0FFEE);

    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;
    uint256 internal constant PRINCIPAL = 10e18;

    function setUpDiamond() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        AtomicDeskFacet atomicFacet = new AtomicDeskFacet();
        SettlementEscrowFacet escrowFacet = new SettlementEscrowFacet();
        AtomicDeskTestHarnessFacet harnessFacet = new AtomicDeskTestHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(loupeFacet), _selectorsLoupe());
        cuts[2] = _cut(address(ownershipFacet), _selectorsOwnership());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](3);
        addCuts[0] = _cut(address(harnessFacet), _selectorsHarness());
        addCuts[1] = _cut(address(atomicFacet), _selectorsAtomicDesk());
        addCuts[2] = _cut(address(escrowFacet), _selectorsEscrow());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        harness = IAtomicDeskTestHarness(address(diamond));
        atomicDesk = AtomicDeskFacet(address(diamond));
        escrow = SettlementEscrowFacet(address(diamond));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);

        escrow.setRefundSafetyWindow(2 days);
        mailbox = new Mailbox(address(diamond));
        escrow.configureMailbox(address(mailbox));
    }

    function _createDesk(bool baseIsA)
        internal
        returns (bytes32 deskId, bytes32 positionKey, uint256 positionId)
    {
        positionId = nft.mint(maker, POOL_A);
        positionKey = nft.getPositionKey(positionId);

        harness.seedPool(POOL_A, address(tokenA), positionKey, PRINCIPAL, PRINCIPAL);
        harness.seedPool(POOL_B, address(tokenB), positionKey, PRINCIPAL, PRINCIPAL);
        harness.joinPool(positionKey, POOL_A);
        harness.joinPool(positionKey, POOL_B);

        vm.prank(maker);
        deskId = atomicDesk.registerDesk(positionId, POOL_A, POOL_B, baseIsA);
    }

    function _reserve(bytes32 deskId, address asset, uint256 amount) internal returns (bytes32 reservationId) {
        bytes32 settlementDigest = keccak256("settlement-digest");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        reservationId = atomicDesk.reserveAtomicSwap(deskId, taker, asset, amount, settlementDigest, expiry);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsLoupe() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectorsOwnership() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = AtomicDeskTestHarnessFacet.setPositionNFT.selector;
        s[1] = AtomicDeskTestHarnessFacet.seedPool.selector;
        s[2] = AtomicDeskTestHarnessFacet.joinPool.selector;
        s[3] = AtomicDeskTestHarnessFacet.getDirectLocked.selector;
        s[4] = AtomicDeskTestHarnessFacet.getPrincipal.selector;
        s[5] = AtomicDeskTestHarnessFacet.getTracked.selector;
        s[6] = AtomicDeskTestHarnessFacet.setTreasury.selector;
    }

    function _selectorsAtomicDesk() internal pure returns (bytes4[] memory s) {
        // setHashlock/getReservation are wired to SettlementEscrow to avoid selector collisions.
        s = new bytes4[](14);
        s[0] = AtomicDeskFacet.setAtomicPaused.selector;
        s[1] = AtomicDeskFacet.registerDesk.selector;
        s[2] = AtomicDeskFacet.setDeskStatus.selector;
        s[3] = AtomicDeskFacet.openTranche.selector;
        s[4] = AtomicDeskFacet.setTrancheStatus.selector;
        s[5] = AtomicDeskFacet.getTranche.selector;
        s[6] = AtomicDeskFacet.reserveFromTranche.selector;
        s[7] = AtomicDeskFacet.getReservationTranche.selector;
        s[8] = AtomicDeskFacet.openTakerTranche.selector;
        s[9] = AtomicDeskFacet.setTakerTrancheStatus.selector;
        s[10] = AtomicDeskFacet.getTakerTranche.selector;
        s[11] = AtomicDeskFacet.reserveFromTakerTranche.selector;
        s[12] = AtomicDeskFacet.setTakerTranchePostingFee.selector;
        s[13] = AtomicDeskFacet.reserveAtomicSwap.selector;
    }

    function _selectorsEscrow() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = SettlementEscrowFacet.setHashlock.selector;
        s[1] = SettlementEscrowFacet.settle.selector;
        s[2] = SettlementEscrowFacet.refund.selector;
        s[3] = SettlementEscrowFacet.getReservation.selector;
        s[4] = SettlementEscrowFacet.setCommittee.selector;
        s[5] = SettlementEscrowFacet.configureMailbox.selector;
        s[6] = SettlementEscrowFacet.configureAtomicDesk.selector;
        s[7] = SettlementEscrowFacet.transferGovernor.selector;
        s[8] = SettlementEscrowFacet.setRefundSafetyWindow.selector;
        s[9] = SettlementEscrowFacet.refundSafetyWindow.selector;
        s[10] = SettlementEscrowFacet.committee.selector;
        s[11] = SettlementEscrowFacet.governor.selector;
        s[12] = SettlementEscrowFacet.mailbox.selector;
        s[13] = SettlementEscrowFacet.atomicDesk.selector;
    }
}

contract AtomicDeskIntegrationTest is AtomicDeskDiamondTestBase {
    function setUp() public {
        setUpDiamond();
    }

    function testReserveLocksAndAuthorizesMailbox() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 amount = 2e18;
        bytes32 reservationId = _reserve(deskId, address(tokenA), amount);

        assertEq(harness.getDirectLocked(positionKey, POOL_A), amount, "collateral locked");
        assertTrue(mailbox.isSlotAuthorized(reservationId), "mailbox authorized");

        AtomicTypes.Reservation memory r = escrow.getReservation(reservationId);
        assertEq(r.positionKey, positionKey, "position key stored");
        assertEq(r.amount, amount, "amount stored");
        assertEq(r.asset, address(tokenA), "asset stored");
        assertEq(r.desk, maker, "desk stored");
        assertEq(r.taker, taker, "taker stored");
        assertEq(uint256(r.status), uint256(AtomicTypes.ReservationStatus.Active), "status active");
    }

    function testSettleUnlocksAndTransfers() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 amount = 3e18;
        bytes32 reservationId = _reserve(deskId, address(tokenA), amount);

        bytes32 tau = keccak256("tau");
        bytes32 hashlock = keccak256(abi.encodePacked(tau));
        vm.prank(maker);
        escrow.setHashlock(reservationId, hashlock);

        uint256 takerBalBefore = tokenA.balanceOf(taker);
        uint256 principalBefore = harness.getPrincipal(POOL_A, positionKey);
        uint256 trackedBefore = harness.getTracked(POOL_A);

        vm.prank(maker);
        escrow.settle(reservationId, tau);

        assertEq(harness.getDirectLocked(positionKey, POOL_A), 0, "collateral unlocked");
        assertEq(harness.getPrincipal(POOL_A, positionKey), principalBefore - amount, "principal reduced");
        assertEq(harness.getTracked(POOL_A), trackedBefore - amount, "tracked reduced");
        assertEq(tokenA.balanceOf(taker), takerBalBefore + amount, "taker received");
        assertFalse(mailbox.isSlotAuthorized(reservationId), "mailbox revoked");

        AtomicTypes.Reservation memory r = escrow.getReservation(reservationId);
        assertEq(uint256(r.status), uint256(AtomicTypes.ReservationStatus.Settled), "status settled");
        assertEq(r.amount, 0, "amount cleared");
    }

    function testRefundUnlocksWithoutTransfer() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 amount = 1e18;
        bytes32 reservationId = _reserve(deskId, address(tokenA), amount);

        escrow.setCommittee(committee, true);
        AtomicTypes.Reservation memory r = escrow.getReservation(reservationId);
        vm.warp(uint256(r.createdAt) + escrow.refundSafetyWindow() + 1);

        uint256 takerBalBefore = tokenA.balanceOf(taker);
        vm.prank(committee);
        escrow.refund(reservationId, keccak256("no-spend"));

        assertEq(harness.getDirectLocked(positionKey, POOL_A), 0, "collateral unlocked");
        assertEq(tokenA.balanceOf(taker), takerBalBefore, "taker unchanged");
        assertFalse(mailbox.isSlotAuthorized(reservationId), "mailbox revoked");

        r = escrow.getReservation(reservationId);
        assertEq(uint256(r.status), uint256(AtomicTypes.ReservationStatus.Refunded), "status refunded");
        assertEq(r.amount, 0, "amount cleared");
    }

    function testTrancheMakerFeeAppliedOnReserve() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 totalLiquidity = 5e18;
        uint256 amount = 2e18;
        uint16 feeBps = 100;
        harness.setTreasury(address(0xBEEF));

        vm.prank(maker);
        bytes32 trancheId = atomicDesk.openTranche(
            deskId,
            totalLiquidity,
            1e18,
            1,
            1,
            feeBps,
            AtomicTypes.FeePayer.Maker,
            0
        );

        uint256 principalBefore = harness.getPrincipal(POOL_A, positionKey);
        uint256 trackedBefore = harness.getTracked(POOL_A);

        bytes32 settlementDigest = keccak256("tranche-settlement");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(taker);
        bytes32 reservationId = atomicDesk.reserveFromTranche(trancheId, amount, settlementDigest, expiry);

        uint256 feeAmount = (amount * feeBps) / 10_000;
        uint256 makerShare = (feeAmount * 7000) / 10_000;
        uint256 protocolFee = feeAmount - makerShare;
        uint256 treasuryShare = (protocolFee * 2000) / 10_000;

        assertEq(harness.getDirectLocked(positionKey, POOL_A), amount, "collateral locked");
        assertEq(
            harness.getPrincipal(POOL_A, positionKey),
            principalBefore - protocolFee,
            "principal net fee"
        );
        assertEq(harness.getTracked(POOL_A), trackedBefore - treasuryShare, "tracked treasury");

        AtomicTypes.Reservation memory r = escrow.getReservation(reservationId);
        assertEq(r.feeBps, feeBps, "fee bps stored");
        assertEq(uint8(r.feePayer), uint8(AtomicTypes.FeePayer.Maker), "fee payer stored");
    }

    function testTakerTrancheTakerFeeAppliedOnSettle() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 totalLiquidity = 4e18;
        uint256 amount = 2e18;
        uint16 feeBps = 200;
        harness.setTreasury(address(0xBEEF));

        vm.prank(taker);
        bytes32 trancheId = atomicDesk.openTakerTranche(
            deskId,
            totalLiquidity,
            1e18,
            1,
            1,
            feeBps,
            AtomicTypes.FeePayer.Taker,
            0
        );

        bytes32 settlementDigest = keccak256("taker-tranche-settlement");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        bytes32 reservationId = atomicDesk.reserveFromTakerTranche(trancheId, amount, settlementDigest, expiry);

        bytes32 tau = keccak256("tau");
        bytes32 hashlock = keccak256(abi.encodePacked(tau));
        vm.prank(maker);
        escrow.setHashlock(reservationId, hashlock);

        uint256 principalBefore = harness.getPrincipal(POOL_A, positionKey);
        uint256 trackedBefore = harness.getTracked(POOL_A);
        uint256 takerBalBefore = tokenA.balanceOf(taker);

        vm.prank(maker);
        escrow.settle(reservationId, tau);

        uint256 feeAmount = (amount * feeBps) / 10_000;
        uint256 makerShare = (feeAmount * 7000) / 10_000;
        uint256 protocolFee = feeAmount - makerShare;
        uint256 treasuryShare = (protocolFee * 2000) / 10_000;
        uint256 payout = amount - feeAmount;

        assertEq(tokenA.balanceOf(taker), takerBalBefore + payout, "taker payout");
        assertEq(
            harness.getPrincipal(POOL_A, positionKey),
            principalBefore - amount + makerShare,
            "principal net settle"
        );
        assertEq(
            harness.getTracked(POOL_A),
            trackedBefore - payout - treasuryShare,
            "tracked net settle"
        );
    }

    function testMailboxEnvelopeFlow() public {
        (bytes32 deskId,,) = _createDesk(true);
        bytes32 reservationId = _reserve(deskId, address(tokenA), 5e17);

        bytes memory context = hex"1234";
        bytes memory presig = hex"abcd";
        bytes memory finalSig = hex"beef";

        vm.prank(taker);
        mailbox.publishContext(reservationId, context);
        vm.prank(maker);
        mailbox.publishPreSig(reservationId, presig);
        vm.prank(taker);
        mailbox.publishFinalSig(reservationId, finalSig);

        bytes[] memory envelopes = mailbox.fetch(reservationId);
        assertEq(envelopes.length, 3, "envelope count");
        assertEq(keccak256(envelopes[0]), keccak256(context), "context stored");
        assertEq(keccak256(envelopes[1]), keccak256(presig), "presig stored");
        assertEq(keccak256(envelopes[2]), keccak256(finalSig), "final stored");
    }
}

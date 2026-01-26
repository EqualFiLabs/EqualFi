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
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {LoanViewFacet} from "../../src/views/LoanViewFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibLoanHelpers} from "../../src/libraries/LibLoanHelpers.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Harness facet for configuring pools and PositionNFT for integration tests.
contract FixedTermPenaltyHarnessFacet is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPoolWithFixed(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint16 ltvBps,
        uint16 rollingApy,
        uint40 durationSecs,
        uint16 apyBps
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.minTopupAmount = minTopup;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.rollingApyBps = rollingApy;
        p.poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function principalOf(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].userPrincipal[key];
    }

    function activeFixedLoanCount(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].activeFixedLoanCount[key];
    }
}

interface IFixedTermPenaltyHarness {
    function configurePositionNFT(address nft) external;
    function initPoolWithFixed(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint16 ltvBps,
        uint16 rollingApy,
        uint40 durationSecs,
        uint16 apyBps
    ) external;
    function principalOf(uint256 pid, bytes32 key) external view returns (uint256);
    function activeFixedLoanCount(uint256 pid, bytes32 key) external view returns (uint256);
    function mintPosition(uint256 pid) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

contract FixedTermPenaltyIntegrationTest is Test {
    Diamond internal diamond;
    PositionNFT internal nft;
    MockERC20 internal token;

    IFixedTermPenaltyHarness internal harness;
    LendingFacet internal lending;
    PenaltyFacet internal penalty;
    LoanViewFacet internal loanView;

    address internal user = address(0xA11CE);
    address internal enforcer = address(0xBEEF);

    uint256 internal constant PID = 1;
    uint256 internal constant PRINCIPAL = 200 ether;
    uint256 internal constant LOAN_AMOUNT = 50 ether;
    uint40 internal constant TERM = 30 days;
    uint16 internal constant LTV_BPS = 8000;

    function setUp() public {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        FixedTermPenaltyHarnessFacet pmFacet = new FixedTermPenaltyHarnessFacet();
        LendingFacet lendingFacet = new LendingFacet();
        PenaltyFacet penaltyFacet = new PenaltyFacet();
        LoanViewFacet loanViewFacet = new LoanViewFacet();

        IDiamondCut.FacetCut[] memory baseCuts = new IDiamondCut.FacetCut[](3);
        baseCuts[0] = _cut(address(cut), _selectors(cut));
        baseCuts[1] = _cut(address(loupe), _selectors(loupe));
        baseCuts[2] = _cut(address(own), _selectors(own));
        diamond = new Diamond(baseCuts, Diamond.DiamondArgs({owner: address(this)}));

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](4);
        addCuts[0] = _cut(address(pmFacet), _selectors(pmFacet));
        addCuts[1] = _cut(address(lendingFacet), _selectors(lendingFacet));
        addCuts[2] = _cut(address(penaltyFacet), _selectors(penaltyFacet));
        addCuts[3] = _cut(address(loanViewFacet), loanViewFacet.selectors());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        harness = IFixedTermPenaltyHarness(address(diamond));
        lending = LendingFacet(address(diamond));
        penalty = PenaltyFacet(address(diamond));
        loanView = LoanViewFacet(address(diamond));

        nft = new PositionNFT();
        token = new MockERC20("Token", "TOK", 18, 0);

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));

        harness.initPoolWithFixed(PID, address(token), 1, 1, 1, LTV_BPS, 0, TERM, 1000);

        token.mint(user, 1_000 ether);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);
    }

    function testFixedTermDefaultAfterExpiryAppliesPenalty() public {
        vm.startPrank(user);
        uint256 tokenId = harness.mintPosition(PID);
        harness.depositToPosition(tokenId, PID, PRINCIPAL);
        uint256 loanId = lending.openFixedFromPosition(tokenId, PID, LOAN_AMOUNT, 0);
        vm.stopPrank();

        bytes32 key = nft.getPositionKey(tokenId);
        vm.warp(block.timestamp + TERM + 1);

        vm.prank(enforcer);
        penalty.penalizePositionFixed(tokenId, PID, loanId, enforcer);

        Types.FixedTermLoan memory loan = loanView.getFixedLoan(PID, loanId);
        assertTrue(loan.closed, "fixed loan not closed");
        assertEq(loan.principalRemaining, 0, "principal remaining not cleared");
        assertEq(harness.activeFixedLoanCount(PID, key), 0, "active fixed count not cleared");
        assertEq(loanView.getUserFixedLoanIds(PID, key).length, 0, "fixed loan id not removed");

        uint256 penaltyAmount = LibLoanHelpers.calculatePenalty(PRINCIPAL);
        uint256 penaltyApplied = penaltyAmount < LOAN_AMOUNT ? penaltyAmount : LOAN_AMOUNT;
        uint256 totalSeized = LOAN_AMOUNT + penaltyApplied;
        assertEq(harness.principalOf(PID, key), PRINCIPAL - totalSeized, "principal not reduced by total seized");
    }

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

    function _selectors(FixedTermPenaltyHarnessFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = FixedTermPenaltyHarnessFacet.configurePositionNFT.selector;
        s[1] = FixedTermPenaltyHarnessFacet.initPoolWithFixed.selector;
        s[2] = FixedTermPenaltyHarnessFacet.principalOf.selector;
        s[3] = FixedTermPenaltyHarnessFacet.activeFixedLoanCount.selector;
        s[4] = PositionManagementFacet.mintPosition.selector;
        s[5] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256)"));
    }

    function _selectors(PenaltyFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,uint256,address)"));
    }
}

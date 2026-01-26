// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract DummyReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract PenaltyHarness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function seedFixedState(
        uint256 pid,
        address underlying,
        bytes32 borrower,
        uint256 principal,
        uint256 loanId,
        uint256 loanPrincipal
    ) external {
        console.log("seed: start");
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        console.log("seed: underlying set");
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        console.log("seed: indexes set");
        p.userPrincipal[borrower] = principal;
        p.userFeeIndex[borrower] = p.feeIndex;
        p.userMaintenanceIndex[borrower] = p.maintenanceIndex;
        p.totalDeposits = principal;
        p.trackedBalance = principal * 2;
        p.userCount = 1;
        LibPoolMembership._ensurePoolMembership(borrower, pid, true);
        console.log("seed: base balances set");
        console.log("seed principal stored", p.userPrincipal[borrower]);

        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = loanPrincipal;
        loan.principalRemaining = loanPrincipal;
        loan.principalAtOpen = loanPrincipal;
        loan.fullInterest = 0;
        // Avoid underflow when block.timestamp is small in tests
        uint40 nowTs = uint40(block.timestamp);
        loan.openedAt = nowTs;
        loan.expiry = nowTs;
        loan.apyBps = 0;
        loan.borrower = borrower;
        loan.closed = false;
        loan.interestRealized = true;
        console.log("seed: loan set");

        p.userFixedLoanIds[borrower].push(loanId);
        p.loanIdToIndex[borrower][loanId] = 0;
        p.activeFixedLoanCount[borrower] = 1;
        console.log("seed: loan arrays set");

        // Fund contract balance
        MockERC20(underlying).mint(address(this), principal * 2);
        console.log("seed: minted funds");

        // Set treasury to non-zero to exercise path
        LibAppStorage.s().treasury = address(0xBEEF);
        console.log("seed: treasury set");
    }

    function getPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].userPrincipal[key];
    }

    function getFixedLoan(uint256 pid, uint256 loanId) external view returns (Types.FixedTermLoan memory) {
        return s().pools[pid].fixedTermLoans[loanId];
    }
}

contract PenaltyHarnessDebugTest is Test {
    PenaltyHarness internal facet;
    MockERC20 internal token;
    PositionNFT internal nft;
    DummyReceiver internal holder;
    uint256 internal constant PID = 1;
    uint256 internal constant LOAN_ID = 1;
    bytes32 internal borrower;
    address internal enforcer = address(0xBEEF);
    uint256 internal tokenId;

    function setUp() public {
        facet = new PenaltyHarness();
        token = new MockERC20("T", "T", 18, 0);
        nft = new PositionNFT();
        holder = new DummyReceiver();
        nft.setMinter(address(facet));
        facet.configurePositionNFT(address(nft));
        tokenId = facet.mintFor(address(holder), PID);
        borrower = nft.getPositionKey(tokenId);
    }

    function test_penalizeFixed_simpleHarness() public {
        facet.seedFixedState(PID, address(token), borrower, 50 ether, LOAN_ID, 20 ether);
        Types.FixedTermLoan memory loanBefore = facet.getFixedLoan(PID, LOAN_ID);
        console.log("before closed", loanBefore.closed);
        console.log("before principal", facet.getPrincipal(PID, borrower));
        // Should not revert and should clear principal/loan
        facet.penalizePositionFixed(1, PID, LOAN_ID, enforcer);
        Types.FixedTermLoan memory loanAfter = facet.getFixedLoan(PID, LOAN_ID);
        console.log("after closed", loanAfter.closed);
        console.log("after principal", facet.getPrincipal(PID, borrower));
        assertEq(facet.getPrincipal(PID, borrower), 29 ether, "principal reduced by seized total");
        assertTrue(loanAfter.closed, "loan closed");
    }
}

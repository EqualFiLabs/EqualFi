// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract PenaltyFeeIndexHarness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint16 penaltyEpochs) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = address(0);
        store.defaultMaintenanceRateBps = 0;

        Types.PoolData storage p = store.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.poolConfig.maintenanceRateBps = 0;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        store.rollingPenaltyEpochs = uint8(penaltyEpochs);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setDepositor(
        uint256 pid,
        bytes32 positionKey,
        uint256 principal,
        uint256 userFeeIndex,
        uint256 userMaintenanceIndex
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        LibPoolMembership.s().joined[positionKey][pid] = true;
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = userFeeIndex;
        p.userMaintenanceIndex[positionKey] = userMaintenanceIndex;
    }

    function setPoolTotals(uint256 pid, uint256 totalDeposits, uint256 trackedBalance, uint256 userCount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.userCount = userCount;
    }

    function seedRollingDelinquent(uint256 pid, bytes32 positionKey, uint256 principalRemaining, uint8 missedPayments)
        external
    {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.active = true;
        loan.depositBacked = true;
        loan.principalRemaining = principalRemaining;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 1 days;
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.principalAtOpen = LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function seedFixedExpired(
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 principalRemaining,
        uint40 expiry
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.borrower = positionKey;
        loan.principalRemaining = principalRemaining;
        loan.closed = false;
        loan.expiry = expiry;
        loan.principalAtOpen = p.userPrincipal[positionKey];

        uint256 idx = p.userFixedLoanIds[positionKey].length;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = idx;
        p.activeFixedLoanCount[positionKey] += 1;
        p.fixedTermPrincipalRemaining[positionKey] += principalRemaining;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function positionKeyOf(uint256 tokenId) external view returns (bytes32) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
    }

    function pendingYieldViaLib(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function totalDebt(uint256 pid, bytes32 positionKey_) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 debt = p.rollingLoans[positionKey_].principalRemaining;
        uint256[] storage ids = p.userFixedLoanIds[positionKey_];
        for (uint256 i; i < ids.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[ids[i]];
            if (!loan.closed) debt += loan.principalRemaining;
        }
        return debt;
    }

    function principalOf(uint256 pid, bytes32 positionKey_) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey_];
    }
}

contract DummyReceiver2 is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract PenaltyFeeIndexPropertyTest is Test {
    uint256 internal constant PID = 1;
    uint256 internal constant COLLATERAL = 100 ether;
    uint256 internal constant DEPOSITOR_PRINCIPAL = 100 ether;

    address internal constant TREASURY = address(0x9999);
    address internal constant LIQUIDATOR = address(0xBEEF);

    MockERC20 internal token;
    PositionNFT internal nft;
    PenaltyFeeIndexHarness internal facet;
    DummyReceiver2 internal receiver;

    function setUp() public {
        token = new MockERC20("Token", "TOK", 18, 0);
        nft = new PositionNFT();
        facet = new PenaltyFeeIndexHarness();
        receiver = new DummyReceiver2();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 3);
        facet.setTreasury(TREASURY);

        // Ensure the facet has enough tokens to pay enforcer+treasury shares during penalty.
        token.mint(address(facet), 1_000_000 ether);
    }

    function test_penalty_accruesFeeIndexToRemainingDepositors_rolling() public {
        uint256 tokenIdA = facet.mintFor(address(receiver), PID);
        bytes32 keyA = facet.positionKeyOf(tokenIdA);

        uint256 tokenIdB = facet.mintFor(address(receiver), PID);
        bytes32 keyB = facet.positionKeyOf(tokenIdB);

        facet.setDepositor(PID, keyA, COLLATERAL, LibFeeIndex.INDEX_SCALE, LibFeeIndex.INDEX_SCALE);
        facet.setDepositor(PID, keyB, DEPOSITOR_PRINCIPAL, LibFeeIndex.INDEX_SCALE, LibFeeIndex.INDEX_SCALE);
        facet.setPoolTotals(PID, COLLATERAL + DEPOSITOR_PRINCIPAL, 1_000_000 ether, 2);

        facet.seedRollingDelinquent(PID, keyA, 50 ether, 3);

        uint256 before = facet.pendingYieldViaLib(PID, keyB);
        facet.penalizePositionRolling(tokenIdA, PID, LIQUIDATOR);
        uint256 afterY = facet.pendingYieldViaLib(PID, keyB);

        uint256 penalty = (COLLATERAL * 500) / 10_000;
        uint256 penaltyApplied = penalty < 50 ether ? penalty : 50 ether;
        uint256 enforcerShare = penaltyApplied / 10;
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        uint256 treasuryShare = (protocolAmount * 2000) / 10_000;
        uint256 feeIndexShare = protocolAmount - treasuryShare;
        uint256 totalSeized = 50 ether + penaltyApplied;
        uint256 totalDepositsAfter = COLLATERAL + DEPOSITOR_PRINCIPAL - totalSeized;
        uint256 expectedYield = (feeIndexShare * DEPOSITOR_PRINCIPAL) / totalDepositsAfter;
        assertApproxEqAbs(afterY - before, expectedYield, 100, "remaining depositor should receive feeIndex share");
        assertEq(facet.principalOf(PID, keyA), COLLATERAL - totalSeized, "collateral reduced by seized total");
        assertEq(facet.totalDebt(PID, keyA), 0, "debt cleared after penalty");
    }

    function test_penalty_accruesFeeIndexToRemainingDepositors_fixed() public {
        uint256 tokenIdA = facet.mintFor(address(receiver), PID);
        bytes32 keyA = facet.positionKeyOf(tokenIdA);

        uint256 tokenIdB = facet.mintFor(address(receiver), PID);
        bytes32 keyB = facet.positionKeyOf(tokenIdB);

        facet.setDepositor(PID, keyA, COLLATERAL, LibFeeIndex.INDEX_SCALE, LibFeeIndex.INDEX_SCALE);
        facet.setDepositor(PID, keyB, DEPOSITOR_PRINCIPAL, LibFeeIndex.INDEX_SCALE, LibFeeIndex.INDEX_SCALE);
        facet.setPoolTotals(PID, COLLATERAL + DEPOSITOR_PRINCIPAL, 1_000_000 ether, 2);

        facet.seedFixedExpired(PID, keyA, 1, 25 ether, uint40(block.timestamp));

        uint256 before = facet.pendingYieldViaLib(PID, keyB);
        facet.penalizePositionFixed(tokenIdA, PID, 1, LIQUIDATOR);
        uint256 afterY = facet.pendingYieldViaLib(PID, keyB);

        uint256 penalty = (COLLATERAL * 500) / 10_000;
        uint256 penaltyApplied = penalty < 25 ether ? penalty : 25 ether;
        uint256 enforcerShare = penaltyApplied / 10;
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        uint256 treasuryShare = (protocolAmount * 2000) / 10_000;
        uint256 feeIndexShare = protocolAmount - treasuryShare;
        uint256 totalSeized = 25 ether + penaltyApplied;
        uint256 totalDepositsAfter = COLLATERAL + DEPOSITOR_PRINCIPAL - totalSeized;
        uint256 expectedYield = (feeIndexShare * DEPOSITOR_PRINCIPAL) / totalDepositsAfter;
        assertApproxEqAbs(afterY - before, expectedYield, 100, "remaining depositor should receive feeIndex share");
        assertEq(facet.principalOf(PID, keyA), COLLATERAL - totalSeized, "collateral reduced by seized total");
        assertEq(facet.totalDebt(PID, keyA), 0, "debt cleared after penalty");
    }
}

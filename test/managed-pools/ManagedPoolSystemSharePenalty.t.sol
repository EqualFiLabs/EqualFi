// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract ManagedPenaltyHarness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(
        uint256 pid,
        address underlying,
        bool isManaged,
        uint256 totalDeposits,
        uint256 trackedBalance
    ) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = address(0);

        Types.PoolData storage p = store.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.isManagedPool = isManaged;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.poolConfig.maintenanceRateBps = 0;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPenaltyEpochs(uint8 delinquent, uint8 penalty) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.rollingDelinquencyEpochs = delinquent;
        store.rollingPenaltyEpochs = penalty;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        LibPoolMembership.s().joined[positionKey][pid] = true;
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function seedRollingLoan(
        uint256 pid,
        bytes32 positionKey,
        uint256 principalRemaining,
        uint256 principalAtOpen,
        uint8 missedPayments
    ) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.principal = principalRemaining;
        loan.principalRemaining = principalRemaining;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 1 days;
        loan.depositBacked = true;
        loan.active = true;
        loan.principalAtOpen = principalAtOpen;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }
}

contract ManagedPoolSystemSharePenaltyTest is Test, IERC721Receiver {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;

    ManagedPenaltyHarness private facet;
    PositionNFT private nft;
    MockERC20 private token;

    function setUp() public {
        facet = new ManagedPenaltyHarness();
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 0);

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));

        facet.setTreasury(address(0));
        facet.setManagedPoolSystemShareBps(2000);
        facet.setPenaltyEpochs(1, 1);

        token.mint(address(facet), 10_000 ether);

        facet.initPool(BASE_PID, address(token), false, 1000 ether, 5000 ether);
        facet.initPool(MANAGED_PID, address(token), true, 1000 ether, 5000 ether);
        facet.setAssetToPoolId(address(token), BASE_PID);
    }

    function testPenaltyRoutesSystemShareToBasePool() public {
        uint256 principal = 1000 ether;
        uint256 loanPrincipalRemaining = 100 ether;

        uint256 tokenId = facet.mintFor(address(this), MANAGED_PID);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(MANAGED_PID, key, principal);
        facet.seedRollingLoan(MANAGED_PID, key, loanPrincipalRemaining, principal, 1);

        uint256 baseBefore = facet.feeIndex(BASE_PID);
        uint256 managedBefore = facet.feeIndex(MANAGED_PID);

        facet.penalizePositionRolling(tokenId, MANAGED_PID, address(0xBEEF));

        uint256 penaltyApplied = (principal * 500) / 10_000; // 5%
        uint256 enforcerShare = penaltyApplied / 10; // 10%
        uint256 protocolAmount = penaltyApplied - enforcerShare;
        uint256 systemShare = (protocolAmount * 2000) / 10_000;
        uint256 managedShare = protocolAmount - systemShare;

        uint256 totalSeized = loanPrincipalRemaining + penaltyApplied;
        uint256 managedTotalDepositsAfter = principal - totalSeized;

        uint256 expectedBaseDelta = (systemShare * LibFeeIndex.INDEX_SCALE) / 1000 ether;
        uint256 expectedManagedDelta = (managedShare * LibFeeIndex.INDEX_SCALE) / managedTotalDepositsAfter;

        uint256 baseAfter = facet.feeIndex(BASE_PID);
        uint256 managedAfter = facet.feeIndex(MANAGED_PID);

        assertEq(baseAfter - baseBefore, expectedBaseDelta, "base fee index delta mismatch");
        assertEq(managedAfter - managedBefore, expectedManagedDelta, "managed fee index delta mismatch");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract PositionManagementIntegrationHarness is PositionManagementFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedRollingDebt(uint256 pid, bytes32 positionKey, uint256 amount) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.active = amount > 0;
        loan.principalRemaining = amount;
    }

    function setFeeIndex(uint256 pid, uint256 value) external {
        LibAppStorage.s().pools[pid].feeIndex = value;
    }

    function settle(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }
}

contract LendingIntegrationHarness is LendingFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function initPool(uint256 pid, address underlying, uint16 ltvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.minLoanAmount = 1;
        p.poolConfig.minTopupAmount = 1;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function addFixedConfig(uint256 pid, uint40 durationSecs, uint16 apyBps) external {
        LibAppStorage.s().pools[pid].poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
        MockERC20(p.underlying).mint(address(this), principal);
    }

    function sameAssetDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateSameAssetDebt(p, positionKey, p.underlying);
    }
}

contract PenaltyIntegrationHarness is PenaltyFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits += principal;
        p.trackedBalance += principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
        MockERC20(p.underlying).mint(address(this), principal);
    }

    function seedFixedLoan(
        uint256 pid,
        bytes32 borrower,
        uint256 loanId,
        uint256 principal
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.principalAtOpen = principal;
        loan.expiry = uint40(block.timestamp);
        p.userFixedLoanIds[borrower].push(loanId);
        p.loanIdToIndex[borrower][loanId] = 0;
        p.activeFixedLoanCount[borrower] = 1;
        p.fixedTermPrincipalRemaining[borrower] = principal;
    }

    function seedRollingDebt(uint256 pid, bytes32 positionKey, uint256 amount) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[positionKey];
        loan.active = amount > 0;
        loan.principalRemaining = amount;
    }

    function pendingYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, positionKey);
    }
}

contract LendingAccountingIntegrationTest is Test {
    MockERC20 internal token;
    PositionNFT internal nft;

    function setUp() public {
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);
        nft = new PositionNFT();
    }

    function test_depositWithdraw_feeBaseUsesNetEquity() public {
        PositionManagementIntegrationHarness facet = new PositionManagementIntegrationHarness();
        facet.setPositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(1, address(token));

        address user = address(0xBEEF);
        token.transfer(user, 200 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);

        vm.prank(user);
        uint256 tokenId = facet.mintPositionWithDeposit(1, 100 ether);
        bytes32 key = nft.getPositionKey(tokenId);

        facet.seedRollingDebt(1, key, 40 ether);
        facet.setFeeIndex(1, 2e18);
        facet.settle(1, key);

        assertEq(facet.accruedYield(1, key), 60 ether, "fee base uses net equity");
    }

    function test_rollingFixedDebt_usesSameAssetDebtAggregation() public {
        LendingIntegrationHarness facet = new LendingIntegrationHarness();
        facet.setPositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(1, address(token), 8000);
        facet.addFixedConfig(1, 30 days, 0);

        address user = address(0xA11CE);
        token.transfer(user, 500 ether);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);

        vm.prank(user);
        uint256 tokenId = facet.mintFor(user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.seedPosition(1, key, 200 ether);

        vm.prank(user);
        facet.openRollingFromPosition(tokenId, 1, 30 ether);
        vm.prank(user);
        facet.openFixedFromPosition(tokenId, 1, 20 ether, 0);

        assertEq(facet.sameAssetDebt(1, key), 50 ether, "same-asset debt aggregates");
    }

    function test_penalty_feeIndexAccruesOnNetEquity() public {
        PenaltyIntegrationHarness facet = new PenaltyIntegrationHarness();
        facet.setPositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(1, address(token));

        address borrower = address(0xB0B);
        address depositor = address(0xD00D);
        uint256 borrowerId = facet.mintFor(borrower, 1);
        uint256 depositorId = facet.mintFor(depositor, 1);
        bytes32 borrowerKey = nft.getPositionKey(borrowerId);
        bytes32 depositorKey = nft.getPositionKey(depositorId);

        facet.setTreasury(address(0xBEEF));
        facet.seedPosition(1, borrowerKey, 100 ether);
        facet.seedPosition(1, depositorKey, 100 ether);
        facet.seedRollingDebt(1, depositorKey, 40 ether);
        facet.seedFixedLoan(1, borrowerKey, 1, 20 ether);

        facet.penalizePositionFixed(borrowerId, 1, 1, address(0xCAFE));

        uint256 yield = facet.pendingYield(1, depositorKey);
        assertGt(yield, 0, "fee index accrued");
        assertLe(yield, 60 ether, "yield respects net equity");
    }
}

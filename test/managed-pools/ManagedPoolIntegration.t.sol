// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActionFees} from "../../src/libraries/LibActionFees.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {WhitelistRequired, LoanBelowMinimum} from "../../src/libraries/Errors.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract ManagedIntegrationHarness is PoolManagementFacet, PositionManagementFacet {
    using SafeERC20 for IERC20;

    event RollingLoanOpenedFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 principal,
        bool depositBacked
    );
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function seedManagedPool(
        uint256 pid,
        address underlying,
        address manager,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.isManagedPool = true;
        p.manager = manager;
        p.whitelistEnabled = true;
        p.whitelist[LibPositionHelpers.systemPositionKey(manager)] = true;
        p.underlying = underlying;
        p.initialized = true;
        p.managedConfig.minDepositAmount = minDeposit;
        p.managedConfig.minLoanAmount = minLoan;
        p.managedConfig.minTopupAmount = minTopup;
        p.managedConfig.depositorLTVBps = 8_000;
        p.managedConfig.isCapped = false;
        p.managedConfig.maxUserCount = 0;
        p.managedConfig.rollingApyBps = 500;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        // Mirror immutable config for legacy call sites that still read poolConfig
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.minTopupAmount = minTopup;
        p.poolConfig.depositorLTVBps = 8_000;
        p.poolConfig.isCapped = false;
        p.poolConfig.maxUserCount = 0;
        p.poolConfig.rollingApyBps = 500;
    }

    function seedUnmanagedPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.minTopupAmount = minTopup;
        p.poolConfig.depositorLTVBps = 8_000;
        p.poolConfig.isCapped = false;
        p.poolConfig.maxUserCount = 0;
        p.poolConfig.rollingApyBps = 500;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function setWhitelist(uint256 pid, bytes32 positionKey, bool allowed) external {
        LibAppStorage.s().pools[pid].whitelist[positionKey] = allowed;
    }

    function poolManager(uint256 pid) external view returns (address) {
        return LibAppStorage.s().pools[pid].manager;
    }

    // Minimal rolling borrow helper mirroring LendingFacet logic for integration assertions
    function openRollingForTest(uint256 tokenId, uint256 pid, uint256 amount) external {
        _requireOwnership(tokenId);
        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        _ensurePoolMembership(positionKey, pid, true);
        require(amount > 0, "PositionNFT: amount=0");
        if (amount < p.poolConfig.minLoanAmount) {
            revert LoanBelowMinimum(amount, p.poolConfig.minLoanAmount);
        }
        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        require(loan.principalRemaining == 0, "PositionNFT: loan exists");
        LibFeeIndex.settle(pid, positionKey);

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 lockedDirect = LibEncumbrance.position(positionKey, pid).directLocked;
        uint256 principalBalance = p.userPrincipal[positionKey];
        require(principalBalance >= lockedDirect, "PositionNFT: locked exceeds principal");
        uint256 collateralValue = principalBalance - lockedDirect;
        require(collateralValue > 0, "PositionNFT: no principal");
        uint256 existingBorrowed = _calculateTotalDebt(p, positionKey, pid);
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, positionKey, p.underlying);
        collateralValue = LibNetEquity.calculateNetEquity(collateralValue, sameAssetDebt);
        require(collateralValue > 0, "PositionNFT: no net equity");

        uint256 newDebt = existingBorrowed + amount;
        require(_checkSolvency(p, positionKey, collateralValue, newDebt), "PositionNFT: LTV exceeded");
        LibActionFees.chargeFromUser(p, pid, LibActionFees.ACTION_BORROW, positionKey);
        require(amount <= p.trackedBalance, "PositionNFT: insufficient pool liquidity");
        p.trackedBalance -= amount;
        IERC20(p.underlying).safeTransfer(msg.sender, amount);

        loan.active = true;
        loan.principalRemaining = amount;
        loan.principalAtOpen = amount;
        loan.depositBacked = true;
        emit RollingLoanOpenedFromPosition(tokenId, msg.sender, pid, amount, true);
    }
}

/// **Feature: managed-pools, integration workflows**
/// **Validates: end-to-end managed/unmanaged interaction and whitelist enforcement**
contract ManagedPoolIntegrationTest is Test {
    ManagedIntegrationHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal token;

    address internal manager = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal outsider = address(0xDEAD);

    uint256 constant MANAGED_PID = 1;
    uint256 constant UNMANAGED_PID = 2;

    function setUp() public {
        harness = new ManagedIntegrationHarness();
        nft = new PositionNFT();
        token = new MockERC20("Underlying", "UND", 18, 0);

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(harness));

        harness.seedManagedPool(MANAGED_PID, address(token), manager, 1 ether, 1 ether, 0.1 ether);
        harness.seedUnmanagedPool(UNMANAGED_PID, address(token), 1 ether, 1 ether, 0.1 ether);
    }

    function _mintAndApprove(address to, uint256 amount) internal {
        token.mint(to, amount);
        vm.prank(to);
        token.approve(address(harness), type(uint256).max);
    }

    function testIntegration_ManagedAndUnmanagedWorkflows() public {
        // Manager can create position and deposit in managed pool
        _mintAndApprove(manager, 10 ether);
        vm.prank(manager);
        uint256 managedTokenId = harness.mintPositionWithDeposit(MANAGED_PID, 5 ether);
        assertEq(nft.ownerOf(managedTokenId), manager, "manager owns token");

        // Non-whitelisted user blocked from joining managed pool
        _mintAndApprove(user, 5 ether);
        vm.prank(user);
        vm.expectRevert();
        harness.mintPositionWithDeposit(MANAGED_PID, 1 ether);

        // User mints position, manager whitelists by tokenId, deposit now succeeds
        vm.prank(user);
        uint256 userTokenId = harness.mintPosition(MANAGED_PID);
        vm.prank(manager);
        harness.addToWhitelist(MANAGED_PID, userTokenId);
        vm.prank(user);
        harness.depositToPosition(userTokenId, MANAGED_PID, 2 ether);
        assertEq(nft.ownerOf(userTokenId), user, "user owns managed token");

        // Managed pool lending flows still work for members
        vm.prank(user);
        harness.openRollingForTest(userTokenId, MANAGED_PID, 1 ether);

        // Unmanaged pool remains permissionless
        _mintAndApprove(outsider, 5 ether);
        vm.prank(outsider);
        uint256 unmanagedTokenId = harness.mintPositionWithDeposit(UNMANAGED_PID, 3 ether);
        assertEq(nft.ownerOf(unmanagedTokenId), outsider, "outsider owns unmanaged token");

        // Unmanaged borrow works and is unaffected by managed whitelist
        vm.prank(outsider);
        harness.openRollingForTest(unmanagedTokenId, UNMANAGED_PID, 1 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DirectFacetHarness} from "./DirectFacetHarness.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Shared harness used by direct tests; exposes minimal mutators and view helpers
contract DirectFixture is DirectFacetHarness {
    bytes32 internal constant TEST_ACCRUAL_SOURCE = keccak256("TEST");
    uint16 internal constant DEFAULT_LTV_BPS = 8000;

    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOwner(address owner) external {
        LibDiamond.diamondStorage().contractOwner = owner;
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
    }

    /// @notice Seed pool and join membership; optionally mint tokens to this harness
    function seedPoolWithMembership(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        bool mintToHarness
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        LibPoolMembership._joinPool(positionKey, pid);
        if (mintToHarness) {
            MockERC20(underlying).mint(address(this), principal);
        }
    }

    function seedPoolWithLtv(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint16 depositorLtvBps,
        bool mintToHarness
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLtvBps;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        LibPoolMembership._joinPool(positionKey, pid);
        if (mintToHarness) {
            MockERC20(underlying).mint(address(this), principal);
        }
    }

    /// @notice Add a pool member without resetting existing deposits
    function addPoolMember(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        bool mintToHarness
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (!p.initialized) {
            p.underlying = underlying;
            p.initialized = true;
        }
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits += principal;
        p.trackedBalance += principal;
        LibPoolMembership._joinPool(positionKey, pid);
        if (mintToHarness) {
            MockERC20(underlying).mint(address(this), principal);
        }
    }

    function setRollingDebt(uint256 pid, bytes32 positionKey, uint256 principalRemaining) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        loan.active = principalRemaining > 0;
        loan.principalRemaining = principalRemaining;
        loan.depositBacked = true;
    }

    function setConfig(DirectTypes.DirectConfig memory cfg) external {
        LibDirectStorage.directStorage().config = cfg;
    }

    function setOfferEscrow(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = amount;
    }

    function setEnforceFixedSizeFills(bool enabled) external {
        LibDirectStorage.directStorage().enforceFixedSizeFills = enabled;
    }

    function trancheRemaining(uint256 offerId) external view returns (uint256) {
        return LibDirectStorage.directStorage().trancheRemaining[offerId];
    }

    function offerEscrow(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directOfferEscrow;
    }

    function directLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function directBorrowed(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid];
    }

    function activeCreditEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[positionKey].principal;
    }

    function activeCreditDebt(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateDebt[positionKey].principal;
    }

    function poolActiveCreditTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function setTrancheState(bytes32 lenderKey, uint256 pid, uint256 offerId, uint256 remaining, uint256 escrow) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        ds.trancheRemaining[offerId] = remaining;
        LibEncumbrance.position(lenderKey, pid).directOfferEscrow = escrow;
    }

    function getDirectConfig() external view returns (DirectTypes.DirectConfig memory) {
        return LibDirectStorage.directStorage().config;
    }

    function setAgreement(DirectTypes.DirectAgreement memory agreement) external {
        LibDirectStorage.directStorage().agreements[agreement.agreementId] = agreement;
    }

    function setDirectState(
        bytes32 borrowerKey,
        bytes32 lenderKey,
        uint256 poolId,
        uint256 lenderPoolId,
        uint256 lockAmount,
        uint256 principal,
        uint256 agreementId
    ) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(borrowerKey, poolId).directLocked = lockAmount;
        LibEncumbrance.position(lenderKey, lenderPoolId).directLent = principal;
        ds.directBorrowedPrincipal[borrowerKey][lenderPoolId] = principal;
        ds.activeDirectLentPerPool[lenderPoolId] = principal;
        ds.directSameAssetDebt[borrowerKey][LibAppStorage.s().pools[poolId].underlying] = principal;
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);

        // Seed active credit total for same-asset exposure
        LibAppStorage.s().pools[poolId].activeCreditPrincipalTotal = principal;
    }

    function poolState(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 activeCreditIndex)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        principal = p.userPrincipal[positionKey];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        feeIndex = p.feeIndex;
        activeCreditIndex = p.activeCreditIndex;
    }

    function sameAssetDebt(bytes32 borrower, address asset) external view returns (uint256) {
        return LibDirectStorage.directStorage().directSameAssetDebt[borrower][asset];
    }

    function agreementStatus(uint256 id) external view returns (DirectTypes.DirectStatus) {
        return LibDirectStorage.directStorage().agreements[id].status;
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function setDirectLocked(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].totalDeposits = amount;
    }

    function poolTotals(uint256 pid) external view returns (uint256 totalDeposits, uint256 feeIndex) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.totalDeposits, p.feeIndex);
    }

    function poolTracked(uint256 pid) external view returns (uint256 trackedBalance, uint256 activeCreditIndex) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.trackedBalance, p.activeCreditIndex);
    }

    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function directLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function accrueActive(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].trackedBalance += amount;
        LibActiveCreditIndex.accrueWithSource(pid, amount, TEST_ACCRUAL_SOURCE);
    }

    function settleActive(uint256 pid, bytes32 user) external {
        LibActiveCreditIndex.settle(pid, user);
    }

    function activeDebtState(uint256 pid, bytes32 user) external view returns (Types.ActiveCreditState memory) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateDebt[user];
    }

    function poolActiveCreditIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndex;
    }

    function setTreasuryShare(address treasury, uint16 shareBps) external {
        LibAppStorage.s().treasury = treasury;
        LibAppStorage.s().treasuryShareConfigured = true;
        LibAppStorage.s().treasuryShareBps = shareBps;
    }

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getTotalDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateTotalDebt(p, positionKey, pid);
    }

    function getWithdrawablePrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return LibSolvencyChecks.calculateWithdrawablePrincipal(p, positionKey, pid);
    }

    function getDirectOfferEscrow(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directOfferEscrow;
    }

    function getActiveDirectLent(uint256 pid) external view returns (uint256) {
        return LibDirectStorage.directStorage().activeDirectLentPerPool[pid];
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }
}

/// @notice Base test contract that deploys a shared fixture and NFT for direct tests
abstract contract DirectTestBase is Test {
    DirectFixture internal facet;
    PositionNFT internal nft;

    function setUpBase() internal {
        facet = new DirectFixture();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        facet.setPositionNFT(address(nft));
        facet.setOwner(address(this));
    }
}

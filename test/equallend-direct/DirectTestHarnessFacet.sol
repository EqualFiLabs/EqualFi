// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibDirectHelpers} from "../../src/libraries/LibDirectHelpers.sol";
import {LibDirectRolling} from "../../src/libraries/LibDirectRolling.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Test harness facet with helper functions for direct lending tests
/// @dev Deployed as a separate facet to avoid stack-too-deep when combined with other facets
contract DirectTestHarnessFacet {
    bytes32 internal constant TEST_ACCRUAL_SOURCE = keccak256("TEST");
    uint16 internal constant DEFAULT_LTV_BPS = 8000;

    function setPositionNFT(address nftAddr) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nftAddr;
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
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
    }

    function setPoolTotals(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
    }

    function setRollingConfig(DirectTypes.DirectRollingConfig memory cfg) external {
        LibDirectStorage.directStorage().rollingConfig = cfg;
    }

    function validateRollingOfferParams(
        DirectTypes.DirectRollingOfferParams memory params,
        DirectTypes.DirectRollingConfig memory cfg
    ) external pure {
        LibDirectRolling.validateRollingOfferParams(params, cfg);
    }

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
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.lastMaintenanceTimestamp = p.lastMaintenanceTimestamp == 0 ? uint64(block.timestamp) : p.lastMaintenanceTimestamp;
        LibPoolMembership._joinPool(positionKey, pid);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
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
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.lastMaintenanceTimestamp = p.lastMaintenanceTimestamp == 0 ? uint64(block.timestamp) : p.lastMaintenanceTimestamp;
        LibPoolMembership._joinPool(positionKey, pid);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        if (mintToHarness) {
            MockERC20(underlying).mint(address(this), principal);
        }
    }

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
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits += principal;
        p.trackedBalance += principal;
        LibPoolMembership._joinPool(positionKey, pid);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        if (mintToHarness) {
            MockERC20(underlying).mint(address(this), principal);
        }
    }

    function addPrincipal(uint256 pid, bytes32 positionKey, uint256 amount, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (!p.initialized) {
            p.underlying = underlying;
            p.initialized = true;
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] += amount;
        p.totalDeposits += amount;
        p.trackedBalance += amount;
        LibPoolMembership._joinPool(positionKey, pid);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        MockERC20(underlying).mint(address(this), amount);
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }

    function joinPool(uint256 pid, bytes32 positionKey) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setConfig(DirectTypes.DirectConfig memory cfg) external {
        LibDirectStorage.directStorage().config = cfg;
    }

    function setArrears(uint256 agreementId, uint256 arrears) external {
        LibDirectStorage.directStorage().rollingAgreements[agreementId].arrears = arrears;
    }

    function setPaymentCount(uint256 agreementId, uint16 count) external {
        LibDirectStorage.directStorage().rollingAgreements[agreementId].paymentCount = count;
    }

    function forceNextDue(uint256 agreementId, uint64 nextDue) external {
        LibDirectStorage.directStorage().rollingAgreements[agreementId].nextDue = nextDue;
    }

    function writeOffer(DirectTypes.DirectOffer memory offer) external {
        LibDirectStorage.directStorage().offers[offer.offerId] = offer;
    }

    function setTrancheRemaining(uint256 offerId, uint256 amount) external {
        LibDirectStorage.directStorage().trancheRemaining[offerId] = amount;
    }

    function setCounters(uint256 nextOfferId, uint256 nextAgreementId) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        ds.nextOfferId = nextOfferId;
        ds.nextAgreementId = nextAgreementId;
    }

    function trackLenderOffer(bytes32 positionKey, uint256 offerId) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibDirectStorage.trackLenderOffer(ds, positionKey, offerId);
    }

    function hasOutstandingOffers(bytes32 positionKey) external view returns (bool) {
        return LibDirectStorage.hasOutstandingOffers(positionKey);
    }

    function addBorrowerAgreement(bytes32 borrowerKey, uint256 agreementId) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
    }

    function removeBorrowerAgreement(bytes32 borrowerKey, uint256 agreementId) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibDirectStorage.removeBorrowerAgreement(ds, borrowerKey, agreementId);
    }

    function seedActiveCreditPool(uint256 pid, uint256 totalDeposits, uint256 remainder) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        p.activeCreditIndexRemainder = remainder;
        p.activeCreditPrincipalTotal = 0;
    }

    function setEncumbranceState(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateEncumbrance[user];
        state.principal = principal;
        state.startTime = startTime;
        state.indexSnapshot = p.activeCreditIndex;
        p.activeCreditPrincipalTotal += principal;
        LibActiveCreditIndex.trackState(p, state);
    }

    function setDebtState(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateDebt[user];
        state.principal = principal;
        state.startTime = startTime;
        state.indexSnapshot = p.activeCreditIndex;
        p.activeCreditPrincipalTotal += principal;
        LibActiveCreditIndex.trackState(p, state);
    }

    function applyDebtIncreaseWithEvent(uint256 pid, bytes32 user, uint256 added) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateDebt[user];
        p.activeCreditPrincipalTotal += added;
        LibActiveCreditIndex.applyWeightedIncreaseWithGate(p, state, added, pid, user, true);
    }

    function resetDebtWithEvent(uint256 pid, bytes32 user) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateDebt[user];
        LibActiveCreditIndex.resetIfZeroWithGate(state, pid, user, true);
    }

    function clearDebtState(uint256 pid, bytes32 user) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateDebt[user];
        p.activeCreditPrincipalTotal = 0;
        state.principal = 0;
        state.startTime = 0;
        state.indexSnapshot = 0;
    }

    function applyActiveCreditIncrease(uint256 pid, bytes32 user, uint256 added) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateEncumbrance[user];
        p.activeCreditPrincipalTotal += added;
        LibActiveCreditIndex.applyWeightedIncreaseWithGate(p, state, added, pid, user, false);
        state.indexSnapshot = p.activeCreditIndex;
    }

    function setOfferEscrow(bytes32 positionKey, uint256 pid, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibEncumbrance.position(positionKey, pid).directOfferEscrow = amount;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibActiveCreditIndex.applyEncumbranceDelta(p, pid, positionKey, encBefore, encAfter);
    }

    function setEnforceFixedSizeFills(bool enabled) external {
        LibDirectStorage.directStorage().enforceFixedSizeFills = enabled;
    }

    function setTrancheState(bytes32 lenderKey, uint256 pid, uint256 offerId, uint256 remaining, uint256 escrow) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        ds.trancheRemaining[offerId] = remaining;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(lenderKey, pid);
        LibEncumbrance.position(lenderKey, pid).directOfferEscrow = escrow;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(lenderKey, pid);
        LibActiveCreditIndex.applyEncumbranceDelta(p, pid, lenderKey, encBefore, encAfter);
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
        Types.PoolData storage collateralPool = LibAppStorage.s().pools[poolId];
        Types.PoolData storage lenderPool = LibAppStorage.s().pools[lenderPoolId];
        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, poolId);
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, lenderPoolId);
        LibEncumbrance.position(borrowerKey, poolId).directLocked = lockAmount;
        LibEncumbrance.position(lenderKey, lenderPoolId).directLent = principal;
        uint256 borrowerEncAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, poolId);
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, poolId, borrowerKey, borrowerEncBefore, borrowerEncAfter
        );
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );
        ds.directBorrowedPrincipal[borrowerKey][lenderPoolId] = principal;
        ds.activeDirectLentPerPool[lenderPoolId] = principal;
        ds.directSameAssetDebt[borrowerKey][LibAppStorage.s().pools[poolId].underlying] = principal;
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);
    }

    function setDirectState(
        bytes32 positionKey,
        uint256 pid,
        uint256 locked,
        uint256 lent,
        uint256 borrowed
    ) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibActiveCreditIndex.applyEncumbranceDelta(p, pid, positionKey, encBefore, encAfter);
        ds.directBorrowedPrincipal[positionKey][pid] = borrowed;
    }

    function setDirectBorrowed(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid] = amount;
    }

    function setDirectLocked(bytes32 positionKey, uint256 pid, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, pid);
        LibActiveCreditIndex.applyEncumbranceDelta(p, pid, positionKey, encBefore, encAfter);
    }

    function setRollingDebt(uint256 pid, bytes32 positionKey, uint256 principalRemaining) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        loan.active = principalRemaining > 0;
        loan.principalRemaining = principalRemaining;
        loan.depositBacked = true;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].totalDeposits = amount;
    }

    function setTreasuryShare(address treasury, uint16 shareBps) external {
        LibAppStorage.s().treasury = treasury;
        LibAppStorage.s().treasuryShareConfigured = true;
        LibAppStorage.s().treasuryShareBps = shareBps;
    }

    function setActiveCreditShare(uint16 shareBps) external {
        LibAppStorage.s().activeCreditShareConfigured = true;
        LibAppStorage.s().activeCreditShareBps = shareBps;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.lastMaintenanceTimestamp = p.lastMaintenanceTimestamp == 0 ? uint64(block.timestamp) : p.lastMaintenanceTimestamp;
    }

    function initPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint16 ltvBps
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.lastMaintenanceTimestamp = p.lastMaintenanceTimestamp == 0 ? uint64(block.timestamp) : p.lastMaintenanceTimestamp;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
        p.lastMaintenanceTimestamp = p.lastMaintenanceTimestamp == 0 ? uint64(block.timestamp) : p.lastMaintenanceTimestamp;
        LibPoolMembership._joinPool(positionKey, pid);
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal, uint256 trackedBalance) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.poolConfig.depositorLTVBps == 0) {
            p.poolConfig.depositorLTVBps = DEFAULT_LTV_BPS;
        }
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits += principal;
        p.trackedBalance = trackedBalance;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }

    function accrueActive(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].trackedBalance += amount;
        LibActiveCreditIndex.accrueWithSource(pid, amount, TEST_ACCRUAL_SOURCE);
    }

    function forceActiveBase(uint256 pid, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.activeCreditPrincipalTotal = amount;
        p.activeCreditMaturedTotal = amount;
        if (p.activeCreditPendingStartHour == 0) {
            p.activeCreditPendingStartHour = uint64(block.timestamp / 1 hours) + 1;
        }
    }

    function accrueActiveCredit(uint256 pid, uint256 amount, bytes32 source) external {
        LibActiveCreditIndex.accrueWithSource(pid, amount, source);
    }

    function settleActive(uint256 pid, bytes32 user) external {
        LibActiveCreditIndex.settle(pid, user);
    }
}

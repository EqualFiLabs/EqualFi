// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

// Production facets
import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectAgreementFacet} from "../../src/equallend-direct/EqualLendDirectAgreementFacet.sol";
import {EqualLendDirectLifecycleFacet} from "../../src/equallend-direct/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "../../src/equallend-direct/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "../../src/equallend-direct/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "../../src/equallend-direct/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "../../src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol";
import {EqualLendDirectRollingViewFacet} from "../../src/views/EqualLendDirectRollingViewFacet.sol";

// Test harness facets
import {DirectTestHarnessFacet} from "./DirectTestHarnessFacet.sol";
import {DirectTestViewFacet} from "./DirectTestViewFacet.sol";

/// @notice Interface for test harness functions
interface IDirectTestHarness {
    function setPositionNFT(address nft) external;
    function setOwner(address owner) external;
    function setTimelock(address timelock) external;
    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal) external;
    function setPoolTotals(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external;
    function setRollingConfig(DirectTypes.DirectRollingConfig memory cfg) external;
    function validateRollingOfferParams(
        DirectTypes.DirectRollingOfferParams memory params,
        DirectTypes.DirectRollingConfig memory cfg
    ) external;
    function seedPoolWithMembership(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, bool mintToHarness) external;
    function seedPoolWithLtv(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint16 depositorLtvBps, bool mintToHarness) external;
    function addPoolMember(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, bool mintToHarness) external;
    function addPrincipal(uint256 pid, bytes32 positionKey, uint256 amount, address underlying) external;
    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external;
    function joinPool(uint256 pid, bytes32 positionKey) external;
    function setConfig(DirectTypes.DirectConfig memory cfg) external;
    function setArrears(uint256 agreementId, uint256 arrears) external;
    function setPaymentCount(uint256 agreementId, uint16 count) external;
    function forceNextDue(uint256 agreementId, uint64 nextDue) external;
    function writeOffer(DirectTypes.DirectOffer memory offer) external;
    function setTrancheRemaining(uint256 offerId, uint256 amount) external;
    function setCounters(uint256 nextOfferId, uint256 nextAgreementId) external;
    function trackLenderOffer(bytes32 positionKey, uint256 offerId) external;
    function hasOutstandingOffers(bytes32 positionKey) external view returns (bool);
    function addBorrowerAgreement(bytes32 borrowerKey, uint256 agreementId) external;
    function removeBorrowerAgreement(bytes32 borrowerKey, uint256 agreementId) external;
    function seedActiveCreditPool(uint256 pid, uint256 totalDeposits, uint256 remainder) external;
    function setEncumbranceState(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external;
    function setDebtState(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external;
    function applyDebtIncreaseWithEvent(uint256 pid, bytes32 user, uint256 added) external;
    function resetDebtWithEvent(uint256 pid, bytes32 user) external;
    function clearDebtState(uint256 pid, bytes32 user) external;
    function applyActiveCreditIncrease(uint256 pid, bytes32 user, uint256 added) external;
    function setOfferEscrow(bytes32 positionKey, uint256 pid, uint256 amount) external;
    function setEnforceFixedSizeFills(bool enabled) external;
    function setTrancheState(bytes32 lenderKey, uint256 pid, uint256 offerId, uint256 remaining, uint256 escrow) external;
    function setAgreement(DirectTypes.DirectAgreement memory agreement) external;
    function setDirectState(bytes32 borrowerKey, bytes32 lenderKey, uint256 poolId, uint256 lenderPoolId, uint256 lockAmount, uint256 principal, uint256 agreementId) external;
    function setDirectState(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent, uint256 borrowed) external;
    function setDirectBorrowed(bytes32 positionKey, uint256 pid, uint256 amount) external;
    function setDirectLocked(bytes32 positionKey, uint256 pid, uint256 amount) external;
    function setTotalDeposits(uint256 pid, uint256 amount) external;
    function setRollingDebt(uint256 pid, bytes32 positionKey, uint256 principalRemaining) external;
    function configurePositionNFT(address nft) external;
    function initPool(uint256 pid, address underlying) external;
    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external;
    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external;
    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal, uint256 trackedBalance) external;
    function setTreasuryShare(address treasury, uint16 shareBps) external;
    function setActiveCreditShare(uint16 shareBps) external;
    function setNativeTrackedTotal(uint256 amount) external;
    function nativeTrackedTotal() external view returns (uint256);
    function accrueActive(uint256 pid, uint256 amount) external;
    function settleActive(uint256 pid, bytes32 user) external;
    function forceActiveBase(uint256 pid, uint256 amount) external;
    function accrueActiveCredit(uint256 pid, uint256 amount, bytes32 source) external;
}

/// @notice Interface for test view functions
interface IDirectTestView {
    function trancheRemaining(uint256 offerId) external view returns (uint256);
    function offerEscrow(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function enforceFixedSizeFills() external view returns (bool);
    function directCounters() external view returns (uint256 nextOfferId, uint256 nextAgreementId);
    function positionState(bytes32 positionKey, uint256 pid) external view returns (DirectTypes.PositionDirectState memory);
    function borrowerAgreementsPage(bytes32 borrowerKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements, uint256 total);
    function activeCreditPoolView(uint256 pid) external view returns (uint256 totalDeposits, uint256 index, uint256 remainder);
    function pendingYield(uint256 pid, bytes32 user) external view returns (uint256);
    function encumbranceActiveCreditState(uint256 pid, bytes32 user) external view returns (Types.ActiveCreditState memory);
    function activeCreditWeight(uint256 pid, bytes32 user) external view returns (uint256);
    function activeCreditTimeCredit(uint256 pid, bytes32 user) external view returns (uint256);
    function directLent(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function directBorrowed(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function activeCreditEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function activeCreditDebt(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function poolActiveCreditTotal(uint256 pid) external view returns (uint256);
    function poolActiveCreditIndex(uint256 pid) external view returns (uint256);
    function getDirectConfig() external view returns (DirectTypes.DirectConfig memory);
    function setDirectConfig(DirectTypes.DirectConfig calldata config) external;
    function poolState(uint256 pid, bytes32 positionKey) external view returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance, uint256 feeIndex, uint256 activeCreditIndex);
    function sameAssetDebt(bytes32 borrower, address asset) external view returns (uint256);
    function agreementStatus(uint256 id) external view returns (DirectTypes.DirectStatus);
    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool);
    function poolTotals(uint256 pid) external view returns (uint256 totalDeposits, uint256 feeIndex);
    function poolTracked(uint256 pid) external view returns (uint256 trackedBalance, uint256 activeCreditIndex);
    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function activeDebtState(uint256 pid, bytes32 user) external view returns (Types.ActiveCreditState memory);
    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getTotalDebt(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getWithdrawablePrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getDirectOfferEscrow(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getActiveDirectLent(uint256 pid) external view returns (uint256);
    function getTrackedBalance(uint256 pid) external view returns (uint256);
    function getFeeIndex(uint256 pid) external view returns (uint256);
    function pendingActiveCredit(uint256 pid, bytes32 user) external view returns (uint256);
    function getActiveCreditIndex(uint256 pid) external view returns (uint256 index, uint256 remainder, uint256 activePrincipalTotal);
    function getAgreement(uint256 agreementId) external view returns (DirectTypes.DirectAgreement memory);
    function getBorrowerOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerOffer memory);
    function getOffer(uint256 offerId) external view returns (DirectTypes.DirectOffer memory);
    function getBorrowerAgreements(uint256 positionId, uint256 offset, uint256 limit) external view returns (uint256[] memory);
    function directLocked(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function getRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectRatioTrancheOffer memory);
    function getBorrowerRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerRatioTrancheOffer memory);
    function getOfferTranche(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory);
    function getTrancheStatus(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory);
    function isTrancheOffer(uint256 offerId) external view returns (bool);
    function fillsRemaining(uint256 offerId) external view returns (uint256);
    function isTrancheDepleted(uint256 offerId) external view returns (bool);
    function getPositionDirectState(uint256 positionId, uint256 poolId) external view returns (uint256 locked, uint256 lent);
    function directBalances(bytes32 key, uint256 pid) external view returns (uint256 locked, uint256 lent, uint256 borrowed);
}

/// @notice Interface for offer facet functions
interface IDirectOffer {
    function postOffer(DirectTypes.DirectOfferParams calldata params) external returns (uint256);
    function postOffer(DirectTypes.DirectOfferParams calldata params, DirectTypes.DirectTrancheOfferParams calldata trancheParams) external returns (uint256);
    function postBorrowerOffer(DirectTypes.DirectBorrowerOfferParams calldata params) external returns (uint256);
    function postRatioTrancheOffer(DirectTypes.DirectRatioTrancheParams calldata params) external returns (uint256);
    function postBorrowerRatioTrancheOffer(DirectTypes.DirectBorrowerRatioTrancheParams calldata params) external returns (uint256);
    function cancelOffer(uint256 offerId) external;
    function cancelBorrowerOffer(uint256 offerId) external;
    function cancelRatioTrancheOffer(uint256 offerId) external;
    function cancelBorrowerRatioTrancheOffer(uint256 offerId) external;
    function cancelOffersForPosition(bytes32 positionKey) external;
    function cancelOffersForPosition(uint256 positionId) external;
    function hasOpenOffers(bytes32 positionKey) external view returns (bool);
}

/// @notice Interface for agreement facet functions
interface IDirectAgreement {
    function acceptOffer(uint256 offerId, uint256 borrowerPositionId) external returns (uint256);
    function acceptBorrowerOffer(uint256 offerId, uint256 lenderPositionId) external returns (uint256);
    function acceptRatioTrancheOffer(uint256 offerId, uint256 borrowerPositionId, uint256 principalAmount) external returns (uint256);
    function acceptBorrowerRatioTrancheOffer(uint256 offerId, uint256 lenderPositionId, uint256 collateralAmount) external returns (uint256);
}

/// @notice Interface for lifecycle facet functions
interface IDirectLifecycle {
    function repay(uint256 agreementId) external payable;
    function exerciseDirect(uint256 agreementId) external payable;
    function callDirect(uint256 agreementId) external payable;
    function recover(uint256 agreementId) external payable;
}

/// @notice Interface for rolling offer facet functions
interface IDirectRollingOffer {
    function postRollingOffer(DirectTypes.DirectRollingOfferParams calldata params) external returns (uint256);
    function postBorrowerRollingOffer(DirectTypes.DirectRollingBorrowerOfferParams calldata params) external returns (uint256);
    function cancelRollingOffer(uint256 offerId) external;
    function getRollingOffer(uint256 offerId) external view returns (DirectTypes.DirectRollingOffer memory);
    function getRollingBorrowerOffer(uint256 offerId) external view returns (DirectTypes.DirectRollingBorrowerOffer memory);
}

/// @notice Interface for rolling agreement facet functions
interface IDirectRollingAgreement {
    function acceptRollingOffer(uint256 offerId, uint256 callerPositionId) external returns (uint256);
    function getRollingAgreement(uint256 agreementId) external view returns (DirectTypes.DirectRollingAgreement memory);
}

/// @notice Interface for rolling lifecycle facet functions
interface IDirectRollingLifecycle {
    function recoverRolling(uint256 agreementId) external;
    function exerciseRolling(uint256 agreementId) external;
    function repayRollingInFull(uint256 agreementId) external;
}

/// @notice Interface for rolling payment facet functions
interface IDirectRollingPayment {
    function makeRollingPayment(uint256 agreementId, uint256 amount) external;
}

/// @notice Interface for rolling view facet functions
interface IDirectRollingView {
    function calculateRollingPayment(uint256 agreementId) external view returns (uint256 currentInterestDue, uint256 totalDue);
    function getRollingStatus(uint256 agreementId) external view returns (EqualLendDirectRollingViewFacet.RollingStatus memory);
    function aggregateRollingExposure(bytes32 borrowerKey)
        external
        view
        returns (EqualLendDirectRollingViewFacet.RollingExposure memory);
}

/// @notice Base test contract using diamond pattern for direct lending tests
/// @dev Deploys facets separately to avoid stack-too-deep issues
abstract contract DirectDiamondTestBase is Test {
    Diamond internal diamond;
    PositionNFT internal nft;

    // Typed interfaces for cleaner test code
    IDirectTestHarness internal harness;
    IDirectTestView internal views;
    IDirectOffer internal offers;
    IDirectAgreement internal agreements;
    IDirectLifecycle internal lifecycle;
    IDirectRollingOffer internal rollingOffers;
    IDirectRollingAgreement internal rollingAgreements;
    IDirectRollingLifecycle internal rollingLifecycle;
    IDirectRollingPayment internal rollingPayments;
    IDirectRollingView internal rollingViews;

    function setUpDiamond() internal {
        // Deploy core diamond facets
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        // Deploy production facets
        EqualLendDirectOfferFacet offerFacet = new EqualLendDirectOfferFacet();
        EqualLendDirectAgreementFacet agreementFacet = new EqualLendDirectAgreementFacet();
        EqualLendDirectLifecycleFacet lifecycleFacet = new EqualLendDirectLifecycleFacet();
        EqualLendDirectRollingOfferFacet rollingOfferFacet = new EqualLendDirectRollingOfferFacet();
        EqualLendDirectRollingAgreementFacet rollingAgreementFacet = new EqualLendDirectRollingAgreementFacet();
        EqualLendDirectRollingLifecycleFacet rollingLifecycleFacet = new EqualLendDirectRollingLifecycleFacet();
        EqualLendDirectRollingPaymentFacet rollingPaymentFacet = new EqualLendDirectRollingPaymentFacet();
        EqualLendDirectRollingViewFacet rollingViewFacet = new EqualLendDirectRollingViewFacet();

        // Deploy test harness facets
        DirectTestHarnessFacet harnessFacet = new DirectTestHarnessFacet();
        DirectTestViewFacet viewFacet = new DirectTestViewFacet();

        // Build initial cuts for diamond deployment
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(loupeFacet), _selectorsLoupe());
        cuts[2] = _cut(address(ownershipFacet), _selectorsOwnership());

        // Deploy diamond
        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        // Add remaining facets via diamondCut
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](10);
        addCuts[0] = _cut(address(offerFacet), _selectorsOffer());
        addCuts[1] = _cut(address(agreementFacet), _selectorsAgreement());
        addCuts[2] = _cut(address(lifecycleFacet), _selectorsLifecycle());
        addCuts[3] = _cut(address(harnessFacet), _selectorsHarness());
        addCuts[4] = _cut(address(viewFacet), _selectorsView());
        addCuts[5] = _cut(address(rollingOfferFacet), _selectorsRollingOffer());
        addCuts[6] = _cut(address(rollingAgreementFacet), _selectorsRollingAgreement());
        addCuts[7] = _cut(address(rollingLifecycleFacet), _selectorsRollingLifecycle());
        addCuts[8] = _cut(address(rollingPaymentFacet), _selectorsRollingPayment());
        addCuts[9] = _cut(address(rollingViewFacet), _selectorsRollingView());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        // Set up typed interfaces
        harness = IDirectTestHarness(address(diamond));
        views = IDirectTestView(address(diamond));
        offers = IDirectOffer(address(diamond));
        agreements = IDirectAgreement(address(diamond));
        lifecycle = IDirectLifecycle(address(diamond));
        rollingOffers = IDirectRollingOffer(address(diamond));
        rollingAgreements = IDirectRollingAgreement(address(diamond));
        rollingLifecycle = IDirectRollingLifecycle(address(diamond));
        rollingPayments = IDirectRollingPayment(address(diamond));
        rollingViews = IDirectRollingView(address(diamond));

        // Deploy and configure NFT - set test contract as minter first
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));
        harness.setOwner(address(this));
    }

    function finalizePositionNFT() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Selector helpers
    // ─────────────────────────────────────────────────────────────────────────────

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

    function _selectorsOffer() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        // postOffer has two overloads - include both
        s[0] = bytes4(keccak256("postOffer((uint256,uint256,uint256,address,address,uint256,uint16,uint64,uint256,bool,bool,bool))"));
        s[1] = bytes4(keccak256("postOffer((uint256,uint256,uint256,address,address,uint256,uint16,uint64,uint256,bool,bool,bool),(bool,uint256))"));
        s[2] = EqualLendDirectOfferFacet.postBorrowerOffer.selector;
        s[3] = EqualLendDirectOfferFacet.postRatioTrancheOffer.selector;
        s[4] = EqualLendDirectOfferFacet.postBorrowerRatioTrancheOffer.selector;
        s[5] = EqualLendDirectOfferFacet.cancelOffer.selector;
        s[6] = EqualLendDirectOfferFacet.cancelBorrowerOffer.selector;
        s[7] = EqualLendDirectOfferFacet.cancelRatioTrancheOffer.selector;
        s[8] = EqualLendDirectOfferFacet.cancelBorrowerRatioTrancheOffer.selector;
        s[9] = bytes4(keccak256("cancelOffersForPosition(bytes32)"));
        s[10] = bytes4(keccak256("cancelOffersForPosition(uint256)"));
        s[11] = EqualLendDirectOfferFacet.hasOpenOffers.selector;
    }

    function _selectorsAgreement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectAgreementFacet.acceptOffer.selector;
        s[1] = EqualLendDirectAgreementFacet.acceptBorrowerOffer.selector;
        s[2] = EqualLendDirectAgreementFacet.acceptRatioTrancheOffer.selector;
        s[3] = EqualLendDirectAgreementFacet.acceptBorrowerRatioTrancheOffer.selector;
    }

    function _selectorsLifecycle() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectLifecycleFacet.repay.selector;
        s[1] = EqualLendDirectLifecycleFacet.exerciseDirect.selector;
        s[2] = EqualLendDirectLifecycleFacet.callDirect.selector;
        s[3] = EqualLendDirectLifecycleFacet.recover.selector;
    }

    function _selectorsRollingOffer() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = EqualLendDirectRollingOfferFacet.postRollingOffer.selector;
        s[1] = EqualLendDirectRollingOfferFacet.postBorrowerRollingOffer.selector;
        s[2] = EqualLendDirectRollingOfferFacet.cancelRollingOffer.selector;
        s[3] = EqualLendDirectRollingOfferFacet.getRollingOffer.selector;
        s[4] = EqualLendDirectRollingOfferFacet.getRollingBorrowerOffer.selector;
    }

    function _selectorsRollingAgreement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualLendDirectRollingAgreementFacet.acceptRollingOffer.selector;
        s[1] = EqualLendDirectRollingAgreementFacet.getRollingAgreement.selector;
    }

    function _selectorsRollingLifecycle() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingLifecycleFacet.recoverRolling.selector;
        s[1] = EqualLendDirectRollingLifecycleFacet.exerciseRolling.selector;
        s[2] = EqualLendDirectRollingLifecycleFacet.repayRollingInFull.selector;
    }

    function _selectorsRollingPayment() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = EqualLendDirectRollingPaymentFacet.makeRollingPayment.selector;
    }

    function _selectorsRollingView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingViewFacet.calculateRollingPayment.selector;
        s[1] = EqualLendDirectRollingViewFacet.getRollingStatus.selector;
        s[2] = EqualLendDirectRollingViewFacet.aggregateRollingExposure.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](54);
        s[0] = DirectTestHarnessFacet.setPositionNFT.selector;
        s[1] = DirectTestHarnessFacet.setOwner.selector;
        s[2] = DirectTestHarnessFacet.setTimelock.selector;
        s[3] = DirectTestHarnessFacet.seedPool.selector;
        s[4] = DirectTestHarnessFacet.setPoolTotals.selector;
        s[5] = DirectTestHarnessFacet.setRollingConfig.selector;
        s[6] = DirectTestHarnessFacet.validateRollingOfferParams.selector;
        s[7] = DirectTestHarnessFacet.seedPoolWithMembership.selector;
        s[8] = DirectTestHarnessFacet.seedPoolWithLtv.selector;
        s[9] = DirectTestHarnessFacet.addPoolMember.selector;
        s[10] = DirectTestHarnessFacet.addPrincipal.selector;
        s[11] = DirectTestHarnessFacet.setUserPrincipal.selector;
        s[12] = DirectTestHarnessFacet.joinPool.selector;
        s[13] = DirectTestHarnessFacet.setConfig.selector;
        s[14] = DirectTestHarnessFacet.setArrears.selector;
        s[15] = DirectTestHarnessFacet.setPaymentCount.selector;
        s[16] = DirectTestHarnessFacet.forceNextDue.selector;
        s[17] = DirectTestHarnessFacet.writeOffer.selector;
        s[18] = DirectTestHarnessFacet.setTrancheRemaining.selector;
        s[19] = DirectTestHarnessFacet.setCounters.selector;
        s[20] = DirectTestHarnessFacet.trackLenderOffer.selector;
        s[21] = DirectTestHarnessFacet.hasOutstandingOffers.selector;
        s[22] = DirectTestHarnessFacet.addBorrowerAgreement.selector;
        s[23] = DirectTestHarnessFacet.removeBorrowerAgreement.selector;
        s[24] = DirectTestHarnessFacet.seedActiveCreditPool.selector;
        s[25] = DirectTestHarnessFacet.setEncumbranceState.selector;
        s[26] = DirectTestHarnessFacet.setDebtState.selector;
        s[27] = DirectTestHarnessFacet.applyDebtIncreaseWithEvent.selector;
        s[28] = DirectTestHarnessFacet.resetDebtWithEvent.selector;
        s[29] = DirectTestHarnessFacet.clearDebtState.selector;
        s[30] = DirectTestHarnessFacet.applyActiveCreditIncrease.selector;
        s[31] = DirectTestHarnessFacet.setOfferEscrow.selector;
        s[32] = DirectTestHarnessFacet.setEnforceFixedSizeFills.selector;
        s[33] = DirectTestHarnessFacet.setTrancheState.selector;
        s[34] = DirectTestHarnessFacet.setAgreement.selector;
        s[35] = bytes4(keccak256("setDirectState(bytes32,bytes32,uint256,uint256,uint256,uint256,uint256)"));
        s[36] = bytes4(keccak256("setDirectState(bytes32,uint256,uint256,uint256,uint256)"));
        s[37] = DirectTestHarnessFacet.setDirectBorrowed.selector;
        s[38] = DirectTestHarnessFacet.setDirectLocked.selector;
        s[39] = DirectTestHarnessFacet.setTotalDeposits.selector;
        s[40] = DirectTestHarnessFacet.configurePositionNFT.selector;
        s[41] = bytes4(keccak256("initPool(uint256,address)"));
        s[42] = bytes4(keccak256("initPool(uint256,address,uint256,uint256,uint16)"));
        s[43] = bytes4(keccak256("seedPosition(uint256,bytes32,uint256)"));
        s[44] = bytes4(keccak256("seedPosition(uint256,bytes32,uint256,uint256)"));
        s[45] = DirectTestHarnessFacet.setRollingDebt.selector;
        s[46] = DirectTestHarnessFacet.setTreasuryShare.selector;
        s[47] = DirectTestHarnessFacet.accrueActive.selector;
        s[48] = DirectTestHarnessFacet.settleActive.selector;
        s[49] = DirectTestHarnessFacet.forceActiveBase.selector;
        s[50] = DirectTestHarnessFacet.accrueActiveCredit.selector;
        s[51] = DirectTestHarnessFacet.setActiveCreditShare.selector;
        s[52] = DirectTestHarnessFacet.setNativeTrackedTotal.selector;
        s[53] = DirectTestHarnessFacet.nativeTrackedTotal.selector;
    }

    function _selectorsView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](50);
        s[0] = DirectTestViewFacet.trancheRemaining.selector;
        s[1] = DirectTestViewFacet.offerEscrow.selector;
        s[2] = DirectTestViewFacet.enforceFixedSizeFills.selector;
        s[3] = DirectTestViewFacet.directCounters.selector;
        s[4] = DirectTestViewFacet.positionState.selector;
        s[5] = DirectTestViewFacet.borrowerAgreementsPage.selector;
        s[6] = DirectTestViewFacet.activeCreditPoolView.selector;
        s[7] = DirectTestViewFacet.pendingYield.selector;
        s[8] = DirectTestViewFacet.encumbranceActiveCreditState.selector;
        s[9] = DirectTestViewFacet.activeCreditWeight.selector;
        s[10] = DirectTestViewFacet.activeCreditTimeCredit.selector;
        s[11] = DirectTestViewFacet.directLent.selector;
        s[12] = DirectTestViewFacet.directBorrowed.selector;
        s[13] = DirectTestViewFacet.activeCreditEncumbrance.selector;
        s[14] = DirectTestViewFacet.activeCreditDebt.selector;
        s[15] = DirectTestViewFacet.poolActiveCreditTotal.selector;
        s[16] = DirectTestViewFacet.poolActiveCreditIndex.selector;
        s[17] = DirectTestViewFacet.getDirectConfig.selector;
        s[18] = DirectTestViewFacet.poolState.selector;
        s[19] = DirectTestViewFacet.sameAssetDebt.selector;
        s[20] = DirectTestViewFacet.agreementStatus.selector;
        s[21] = DirectTestViewFacet.isMember.selector;
        s[22] = DirectTestViewFacet.poolTotals.selector;
        s[23] = DirectTestViewFacet.poolTracked.selector;
        s[24] = DirectTestViewFacet.accruedYield.selector;
        s[25] = DirectTestViewFacet.activeDebtState.selector;
        s[26] = DirectTestViewFacet.getUserPrincipal.selector;
        s[27] = DirectTestViewFacet.getTotalDebt.selector;
        s[28] = DirectTestViewFacet.getWithdrawablePrincipal.selector;
        s[29] = DirectTestViewFacet.getDirectOfferEscrow.selector;
        s[30] = DirectTestViewFacet.getActiveDirectLent.selector;
        s[31] = DirectTestViewFacet.getTrackedBalance.selector;
        s[32] = DirectTestViewFacet.getFeeIndex.selector;
        s[33] = DirectTestViewFacet.getAgreement.selector;
        s[34] = DirectTestViewFacet.getBorrowerOffer.selector;
        s[35] = DirectTestViewFacet.getOffer.selector;
        s[36] = DirectTestViewFacet.getRatioTrancheOffer.selector;
        s[37] = DirectTestViewFacet.getBorrowerRatioTrancheOffer.selector;
        s[38] = DirectTestViewFacet.getOfferTranche.selector;
        s[39] = DirectTestViewFacet.getTrancheStatus.selector;
        s[40] = DirectTestViewFacet.fillsRemaining.selector;
        s[41] = DirectTestViewFacet.isTrancheOffer.selector;
        s[42] = DirectTestViewFacet.isTrancheDepleted.selector;
        s[43] = DirectTestViewFacet.getPositionDirectState.selector;
        s[44] = DirectTestViewFacet.directBalances.selector;
        s[45] = DirectTestViewFacet.setDirectConfig.selector;
        s[46] = DirectTestViewFacet.getBorrowerAgreements.selector;
        s[47] = DirectTestViewFacet.directLocked.selector;
        s[48] = DirectTestViewFacet.pendingActiveCredit.selector;
        s[49] = DirectTestViewFacet.getActiveCreditIndex.selector;
    }
}

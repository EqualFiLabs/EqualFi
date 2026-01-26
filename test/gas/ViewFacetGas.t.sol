// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ActiveCreditViewFacet} from "../../src/views/ActiveCreditViewFacet.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {EnhancedLoanViewFacet} from "../../src/views/EnhancedLoanViewFacet.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {EqualLendDirectViewFacet} from "../../src/views/EqualLendDirectViewFacet.sol";
import {LiquidityViewFacet} from "../../src/views/LiquidityViewFacet.sol";
import {LoanViewFacet} from "../../src/views/LoanViewFacet.sol";
import {LoanPreviewFacet} from "../../src/views/LoanPreviewFacet.sol";
import {MultiPoolPositionViewFacet} from "../../src/views/MultiPoolPositionViewFacet.sol";
import {PoolUtilizationViewFacet} from "../../src/views/PoolUtilizationViewFacet.sol";
import {PositionViewFacet} from "../../src/views/PositionViewFacet.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {Types} from "../../src/libraries/Types.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract ActiveCreditViewHarness is ActiveCreditViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.activeCreditIndex = 1e18;
    }

    function setActiveCreditState(uint256 pid, bytes32 user, uint256 principal, uint256 indexSnapshot) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userActiveCreditStateEncumbrance[user] = Types.ActiveCreditState({
            principal: principal,
            startTime: uint40(block.timestamp),
            indexSnapshot: indexSnapshot
        });
        p.userActiveCreditStateDebt[user] = Types.ActiveCreditState({
            principal: principal,
            startTime: uint40(block.timestamp),
            indexSnapshot: indexSnapshot
        });
    }

    function setActiveCreditIndex(uint256 pid, uint256 index, uint256 remainder, uint256 total) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.activeCreditIndex = index;
        p.activeCreditIndexRemainder = remainder;
        p.activeCreditPrincipalTotal = total;
    }
}

contract ActiveCreditViewGasTest is Test {
    ActiveCreditViewHarness internal harness;
    PositionNFT internal nft;

    uint256 internal constant PID = 1;
    uint256 internal tokenId;
    bytes32 internal positionKey;

    function setUp() public {
        harness = new ActiveCreditViewHarness();
        nft = new PositionNFT();
        harness.setPositionNFT(address(nft));
        nft.setMinter(address(this));

        tokenId = nft.mint(address(0xA11CE), PID);
        positionKey = nft.getPositionKey(tokenId);
        harness.initPool(PID, address(0xCAFE));
        harness.setActiveCreditState(PID, positionKey, 100 ether, 1e18);
        harness.setActiveCreditIndex(PID, 1e18, 0, 100 ether);
    }

    function test_gas_GetActiveCreditStates() public {
        vm.resumeGasMetering();
        harness.getActiveCreditStates(PID, positionKey);
    }

    function test_gas_GetActiveCreditStatesByPosition() public {
        vm.resumeGasMetering();
        harness.getActiveCreditStatesByPosition(PID, tokenId);
    }

    function test_gas_GetActiveCreditStatus() public {
        vm.resumeGasMetering();
        harness.getActiveCreditStatus(PID, positionKey);
    }

    function test_gas_GetActiveCreditStatusByPosition() public {
        vm.resumeGasMetering();
        harness.getActiveCreditStatusByPosition(PID, tokenId);
    }

    function test_gas_PendingActiveCredit() public {
        vm.resumeGasMetering();
        harness.pendingActiveCredit(PID, positionKey);
    }

    function test_gas_PendingActiveCreditByPosition() public {
        vm.resumeGasMetering();
        harness.pendingActiveCreditByPosition(PID, tokenId);
    }

    function test_gas_GetActiveCreditIndex() public {
        vm.resumeGasMetering();
        harness.getActiveCreditIndex(PID);
    }

    function test_gas_ActiveCreditSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract ConfigViewHarness is ConfigViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.isCapped = true;
        p.poolConfig.depositCap = 1_000 ether;
        p.poolConfig.minDepositAmount = 1 ether;
        p.poolConfig.minLoanAmount = 1 ether;
        p.poolConfig.minTopupAmount = 0.1 ether;
        p.poolConfig.rollingApyBps = 500;
        p.poolConfig.depositorLTVBps = 8000;
        p.poolConfig.maintenanceRateBps = 100;
        p.poolConfig.flashLoanFeeBps = 50;
        p.poolConfig.flashLoanAntiSplit = true;
        p.poolConfig.aumFeeMinBps = 10;
        p.poolConfig.aumFeeMaxBps = 100;
        p.currentAumFeeBps = 10;
        p.totalDeposits = 500 ether;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        p.deprecated = false;
    }

    function setManagedPool(uint256 pid, address manager) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.isManagedPool = true;
        p.manager = manager;
        p.whitelistEnabled = true;
        p.managedConfig.manager = manager;
        p.managedConfig.whitelistEnabled = true;
    }

    function setWhitelist(uint256 pid, bytes32 positionKey, bool enabled) external {
        LibAppStorage.s().pools[pid].whitelist[positionKey] = enabled;
    }

    function setPoolCount(uint256 poolCount) external {
        LibAppStorage.s().poolCount = poolCount;
    }

    function setGlobals(uint16 defaultRate, address receiver, uint8 delinquentEpochs, uint8 penaltyEpochs) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultMaintenanceRateBps = defaultRate;
        store.foundationReceiver = receiver;
        store.rollingDelinquencyEpochs = delinquentEpochs;
        store.rollingPenaltyEpochs = penaltyEpochs;
    }
}

contract ConfigViewGasTest is Test {
    ConfigViewHarness internal harness;
    PositionNFT internal nft;
    uint256 internal constant PID = 1;
    uint256 internal tokenId;

    function setUp() public {
        harness = new ConfigViewHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(address(0xA11CE), PID);
        harness.setPositionNFT(address(nft));
        harness.initPool(PID, address(0xCAFE));
        harness.setManagedPool(PID, address(this));
        harness.setWhitelist(PID, nft.getPositionKey(tokenId), true);
        harness.setPoolCount(1);
        harness.setGlobals(100, address(0xBEEF), 2, 3);
    }

    function test_gas_GetPoolConfig() public {
        vm.resumeGasMetering();
        harness.getPoolConfigSummary(PID);
    }

    function test_gas_GetPoolCaps() public {
        vm.resumeGasMetering();
        harness.getPoolCaps(PID);
    }

    function test_gas_GetMaintenanceState() public {
        vm.resumeGasMetering();
        harness.getMaintenanceState(PID);
    }

    function test_gas_GetFlashConfig() public {
        vm.resumeGasMetering();
        harness.getFlashConfig(PID);
    }

    function test_gas_GetFixedTermConfigs() public {
        vm.resumeGasMetering();
        harness.getFixedTermConfigs(PID);
    }

    function test_gas_GetMinDepositAmount() public {
        vm.resumeGasMetering();
        harness.getMinDepositAmount(PID);
    }

    function test_gas_GetMinLoanAmount() public {
        vm.resumeGasMetering();
        harness.getMinLoanAmount(PID);
    }

    function test_gas_GetPoolConfigFull() public {
        vm.resumeGasMetering();
        harness.getPoolConfig(PID);
    }

    function test_gas_GetAumFeeInfo() public {
        vm.resumeGasMetering();
        harness.getAumFeeInfo(PID);
    }

    function test_gas_IsPoolDeprecated() public {
        vm.resumeGasMetering();
        harness.isPoolDeprecated(PID);
    }

    function test_gas_GetPoolInfo() public {
        vm.resumeGasMetering();
        harness.getPoolInfo(PID);
    }

    function test_gas_GetPoolList() public {
        vm.resumeGasMetering();
        harness.getPoolList(0, 10);
    }

    function test_gas_IsManagedPool() public {
        vm.resumeGasMetering();
        harness.isManagedPool(PID);
    }

    function test_gas_GetPoolManager() public {
        vm.resumeGasMetering();
        harness.getPoolManager(PID);
    }

    function test_gas_IsWhitelistEnabled() public {
        vm.resumeGasMetering();
        harness.isWhitelistEnabled(PID);
    }

    function test_gas_IsWhitelisted() public {
        vm.resumeGasMetering();
        harness.isWhitelisted(PID, tokenId);
    }

    function test_gas_GetManagedPoolConfig() public {
        vm.resumeGasMetering();
        harness.getManagedPoolConfig(PID);
    }

    function test_gas_GetPoolUnderlying() public {
        vm.resumeGasMetering();
        harness.getPoolUnderlying(PID);
    }

    function test_gas_GetRollingDelinquencyThresholds() public {
        vm.resumeGasMetering();
        harness.getRollingDelinquencyThresholds();
    }

    function test_gas_ConfigSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract EnhancedLoanViewHarness is EnhancedLoanViewFacet {
    function initPool(uint256 pid, address underlying, uint16 ltvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = ltvBps;
    }

    function addFixedTermConfig(uint256 pid, Types.FixedTermConfig memory cfg) external {
        LibAppStorage.s().pools[pid].poolConfig.fixedTermConfigs.push(cfg);
    }

    function seedUserPrincipal(uint256 pid, bytes32 borrower, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[borrower] = principal;
    }

    function seedFixedLoan(uint256 pid, bytes32 borrower, uint256 loanId, uint256 principal, bool closed) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.closed = closed;
        p.userFixedLoanIds[borrower].push(loanId);
    }

    function seedRollingLoan(uint256 pid, bytes32 borrower, uint256 principal) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principal;
        loan.active = principal > 0;
    }
}

contract EnhancedLoanViewGasTest is Test {
    EnhancedLoanViewHarness internal harness;
    bytes32 internal constant BORROWER = bytes32(uint256(0xB0B));
    uint256 internal constant PID = 1;

    function setUp() public {
        harness = new EnhancedLoanViewHarness();
        harness.initPool(PID, address(0xCAFE), 8000);
        harness.addFixedTermConfig(PID, Types.FixedTermConfig({durationSecs: 30 days, apyBps: 500}));
        harness.seedUserPrincipal(PID, BORROWER, 100 ether);
        harness.seedFixedLoan(PID, BORROWER, 1, 20 ether, false);
        harness.seedRollingLoan(PID, BORROWER, 10 ether);
    }

    function test_gas_GetUserFixedLoansDetailed() public {
        vm.resumeGasMetering();
        harness.getUserFixedLoansDetailed(PID, BORROWER);
    }

    function test_gas_GetUserFixedLoansPaginated() public {
        vm.resumeGasMetering();
        harness.getUserFixedLoansPaginated(PID, BORROWER, 0, 10);
    }

    function test_gas_GetUserHealthMetrics() public {
        vm.resumeGasMetering();
        harness.getUserHealthMetrics(PID, BORROWER);
    }

    function test_gas_PreviewBorrowFixed() public {
        vm.resumeGasMetering();
        harness.previewBorrowFixed(PID, BORROWER);
    }

    function test_gas_CanOpenFixedLoan() public {
        vm.resumeGasMetering();
        harness.canOpenFixedLoan(PID, BORROWER, 10 ether, 0);
    }

    function test_gas_GetFixedLoanAccrued() public {
        vm.resumeGasMetering();
        harness.getFixedLoanAccrued(PID, 1);
    }

    function test_gas_PreviewRepayFixed() public {
        vm.resumeGasMetering();
        harness.previewRepayFixed(PID, 1, 10 ether);
    }

    function test_gas_EnhancedLoanSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract EqualIndexViewHarness is EqualIndexViewFacetV3 {
    function seedIndex(uint256 indexId, address token, address asset) external {
        EqualIndexStorage storage store = s();
        store.indexCount = indexId + 1;
        Index storage idx = store.indexes[indexId];
        idx.token = token;
        idx.assets.push(asset);
        idx.bundleAmounts.push(1 ether);
        idx.mintFeeBps.push(100);
        idx.burnFeeBps.push(100);
        idx.flashFeeBps = 50;
    }

}

contract EqualIndexViewGasTest is Test {
    EqualIndexViewHarness internal harness;
    uint256 internal constant INDEX_ID = 0;

    function setUp() public {
        harness = new EqualIndexViewHarness();
        harness.seedIndex(INDEX_ID, address(0xBEEF), address(0xCAFE));
    }

    function test_gas_GetIndexAssets() public {
        vm.resumeGasMetering();
        harness.getIndexAssets(INDEX_ID, 0, 10);
    }

    function test_gas_GetIndexAssetCount() public {
        vm.resumeGasMetering();
        harness.getIndexAssetCount(INDEX_ID);
    }

    function test_gas_GetProtocolBalance() public {
        vm.resumeGasMetering();
        harness.getProtocolBalance(address(0xCAFE));
    }
}

contract EqualLendDirectViewHarness is EqualLendDirectViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function seedOffer(DirectTypes.DirectOffer memory offer) external {
        LibDirectStorage.directStorage().offers[offer.offerId] = offer;
    }

    function seedBorrowerOffer(DirectTypes.DirectBorrowerOffer memory offer) external {
        LibDirectStorage.directStorage().borrowerOffers[offer.offerId] = offer;
    }

    function seedRatioOffer(DirectTypes.DirectRatioTrancheOffer memory offer) external {
        LibDirectStorage.directStorage().ratioOffers[offer.offerId] = offer;
    }

    function seedBorrowerRatioOffer(DirectTypes.DirectBorrowerRatioTrancheOffer memory offer) external {
        LibDirectStorage.directStorage().borrowerRatioOffers[offer.offerId] = offer;
    }

    function seedAgreement(DirectTypes.DirectAgreement memory agreement) external {
        LibDirectStorage.directStorage().agreements[agreement.agreementId] = agreement;
    }

    function trackOffers(bytes32 positionKey, uint256 offerId, bool isBorrower, bool isRatioBorrower) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        if (isBorrower) {
            LibDirectStorage.trackBorrowerOffer(ds, positionKey, offerId);
        } else {
            LibDirectStorage.trackLenderOffer(ds, positionKey, offerId);
        }
        if (isRatioBorrower) {
            LibDirectStorage.trackRatioBorrowerOffer(ds, positionKey, offerId);
        } else {
            LibDirectStorage.trackRatioLenderOffer(ds, positionKey, offerId);
        }
    }

    function seedTrancheRemaining(uint256 offerId, uint256 remaining) external {
        LibDirectStorage.directStorage().trancheRemaining[offerId] = remaining;
    }

    function seedDirectState(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent) external {
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
    }

    function seedPoolActiveDirectLent(uint256 pid, uint256 amount) external {
        LibDirectStorage.directStorage().activeDirectLentPerPool[pid] = amount;
    }

    function seedBorrowerAgreement(bytes32 positionKey, uint256 agreementId) external {
        LibDirectStorage.addBorrowerAgreement(LibDirectStorage.directStorage(), positionKey, agreementId);
    }
}

contract EqualLendDirectViewGasTest is Test {
    EqualLendDirectViewHarness internal harness;
    PositionNFT internal nft;
    uint256 internal tokenId;
    bytes32 internal positionKey;

    function setUp() public {
        harness = new EqualLendDirectViewHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(address(0xA11CE), 1);
        positionKey = nft.getPositionKey(tokenId);
        harness.setPositionNFT(address(nft));

        DirectTypes.DirectOffer memory offer = DirectTypes.DirectOffer({
            offerId: 1,
            lender: address(this),
            lenderPositionId: tokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            principal: 10 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false,
            isTranche: true,
            trancheAmount: 10 ether
        });
        harness.seedOffer(offer);

        DirectTypes.DirectBorrowerOffer memory borrowerOffer = DirectTypes.DirectBorrowerOffer({
            offerId: 2,
            borrower: address(this),
            borrowerPositionId: tokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            principal: 10 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false
        });
        harness.seedBorrowerOffer(borrowerOffer);

        DirectTypes.DirectRatioTrancheOffer memory ratioOffer = DirectTypes.DirectRatioTrancheOffer({
            offerId: 3,
            lender: address(this),
            lenderPositionId: tokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            principalCap: 10 ether,
            principalRemaining: 10 ether,
            priceNumerator: 2,
            priceDenominator: 1,
            minPrincipalPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false
        });
        harness.seedRatioOffer(ratioOffer);

        DirectTypes.DirectBorrowerRatioTrancheOffer memory borrowerRatioOffer = DirectTypes.DirectBorrowerRatioTrancheOffer({
            offerId: 4,
            borrower: address(this),
            borrowerPositionId: tokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            collateralCap: 10 ether,
            collateralRemaining: 10 ether,
            priceNumerator: 1,
            priceDenominator: 2,
            minCollateralPerFill: 1 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false
        });
        harness.seedBorrowerRatioOffer(borrowerRatioOffer);

        DirectTypes.DirectAgreement memory agreement = DirectTypes.DirectAgreement({
            agreementId: 1,
            lender: address(this),
            borrower: address(this),
            lenderPositionId: tokenId,
            lenderPoolId: 1,
            borrowerPositionId: tokenId,
            collateralPoolId: 2,
            collateralAsset: address(0xBEEF),
            borrowAsset: address(0xCAFE),
            principal: 10 ether,
            userInterest: 0,
            dueTimestamp: uint64(block.timestamp + 1 days),
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: false
        });
        harness.seedAgreement(agreement);

        harness.seedTrancheRemaining(1, 10 ether);
        harness.seedDirectState(positionKey, 2, 5 ether, 10 ether);
        harness.seedPoolActiveDirectLent(1, 10 ether);
        harness.seedBorrowerAgreement(positionKey, 1);
        harness.trackOffers(positionKey, 1, false, false);
        harness.trackOffers(positionKey, 2, true, false);
        harness.trackOffers(positionKey, 3, false, false);
        harness.trackOffers(positionKey, 4, true, true);
    }

    function test_gas_GetBorrowerOffer() public {
        vm.resumeGasMetering();
        harness.getBorrowerOffer(2);
    }

    function test_gas_GetRatioTrancheOffer() public {
        vm.resumeGasMetering();
        harness.getRatioTrancheOffer(3);
    }

    function test_gas_GetBorrowerRatioTrancheOffer() public {
        vm.resumeGasMetering();
        harness.getBorrowerRatioTrancheOffer(4);
    }

    function test_gas_GetOffer() public {
        vm.resumeGasMetering();
        harness.getOffer(1);
    }

    function test_gas_GetOfferSummary() public {
        vm.resumeGasMetering();
        harness.getOfferSummary(1);
    }

    function test_gas_GetPoolActiveDirectLent() public {
        vm.resumeGasMetering();
        harness.getPoolActiveDirectLent(1);
    }

    function test_gas_GetBorrowerAgreements() public {
        vm.resumeGasMetering();
        harness.getBorrowerAgreements(tokenId, 0, 10);
    }

    function test_gas_GetBorrowerOffers() public {
        vm.resumeGasMetering();
        harness.getBorrowerOffers(tokenId, 0, 10);
    }

    function test_gas_GetLenderOffers() public {
        vm.resumeGasMetering();
        harness.getLenderOffers(tokenId, 0, 10);
    }

    function test_gas_GetRatioLenderOffers() public {
        vm.resumeGasMetering();
        harness.getRatioLenderOffers(tokenId, 0, 10);
    }

    function test_gas_GetRatioBorrowerOffers() public {
        vm.resumeGasMetering();
        harness.getRatioBorrowerOffers(tokenId, 0, 10);
    }

    function test_gas_IsTrancheOffer() public {
        vm.resumeGasMetering();
        harness.isTrancheOffer(1);
    }

    function test_gas_FillsRemaining() public {
        vm.resumeGasMetering();
        harness.fillsRemaining(1);
    }

    function test_gas_IsTrancheDepleted() public {
        vm.resumeGasMetering();
        harness.isTrancheDepleted(1);
    }

    function test_gas_GetOfferTranche() public {
        vm.resumeGasMetering();
        harness.getOfferTranche(1);
    }

    function test_gas_GetTrancheStatus() public {
        vm.resumeGasMetering();
        harness.getTrancheStatus(1);
    }

    function test_gas_GetRatioTrancheStatus() public {
        vm.resumeGasMetering();
        harness.getRatioTrancheStatus(3);
    }

    function test_gas_GetPositionDirectState() public {
        vm.resumeGasMetering();
        harness.getPositionDirectState(tokenId, 2);
    }
}

contract LiquidityViewHarness is LiquidityViewFacet {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedUser(uint256 pid, bytes32 user, uint256 principal, uint256 accrued, uint256 feeIndex) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[user] = principal;
        p.userAccruedYield[user] = accrued;
        p.userFeeIndex[user] = feeIndex;
        p.totalDeposits = principal;
    }
}

contract LiquidityViewGasTest is Test {
    LiquidityViewHarness internal harness;
    MockERC20 internal token;
    uint256 internal constant PID = 1;
    bytes32 internal constant USER = bytes32(uint256(0xB0B));

    function setUp() public {
        harness = new LiquidityViewHarness();
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);
        harness.initPool(PID, address(token));
        harness.seedUser(PID, USER, 100 ether, 5 ether, LibFeeIndex.INDEX_SCALE);
        token.mint(address(harness), 200 ether);
    }

    function test_gas_TotalAvailableLiquidity() public {
        vm.resumeGasMetering();
        harness.totalAvailableLiquidity(PID);
    }

    function test_gas_GetTotalPoolDeposits() public {
        vm.resumeGasMetering();
        harness.getTotalPoolDeposits(PID);
    }

    function test_gas_PendingYield() public {
        vm.resumeGasMetering();
        harness.pendingYield(PID, USER);
    }

    function test_gas_GetUserBalances() public {
        vm.resumeGasMetering();
        harness.getUserBalances(PID, USER);
    }

    function test_gas_LiquiditySelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract LoanViewHarness is LoanViewFacet {
    function initPool(uint256 pid, address underlying, uint16 depositorLtvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLtvBps;
    }

    function setUserPrincipal(uint256 pid, bytes32 user, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[user] = principal;
    }

    function seedRollingLoan(uint256 pid, bytes32 borrower, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principalRemaining;
        loan.active = principalRemaining > 0;
    }

    function seedFixedLoan(uint256 pid, uint256 loanId, bytes32 borrower, uint256 principalRemaining, bool closed)
        external
    {
        Types.FixedTermLoan storage loan = LibAppStorage.s().pools[pid].fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principalRemaining = principalRemaining;
        loan.closed = closed;
    }

    function seedUserFixedLoanIds(uint256 pid, bytes32 borrower, uint256[] calldata loanIds) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        delete p.userFixedLoanIds[borrower];
        for (uint256 i; i < loanIds.length; i++) {
            p.userFixedLoanIds[borrower].push(loanIds[i]);
        }
    }
}

contract LoanViewGasTest is Test {
    LoanViewHarness internal harness;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = bytes32(uint256(0xB0B));

    function setUp() public {
        harness = new LoanViewHarness();
        harness.initPool(PID, address(0xCAFE), 8000);
        harness.setUserPrincipal(PID, BORROWER, 100 ether);
        harness.seedRollingLoan(PID, BORROWER, 10 ether);
        harness.seedFixedLoan(PID, 1, BORROWER, 20 ether, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        harness.seedUserFixedLoanIds(PID, BORROWER, ids);
    }

    function test_gas_GetRollingLoan() public {
        vm.resumeGasMetering();
        harness.getRollingLoan(PID, BORROWER);
    }

    function test_gas_PreviewBorrowRolling() public {
        vm.resumeGasMetering();
        harness.previewBorrowRolling(PID, BORROWER);
    }

    function test_gas_LoanViewSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract LoanPreviewGasTest is Test {
    LoanPreviewFacet internal facet;

    function setUp() public {
        facet = new LoanPreviewFacet();
    }

    function test_gas_LoanPreviewSelectors() public {
        vm.resumeGasMetering();
        facet.selectors();
    }
}

contract MultiPoolPositionViewHarness is MultiPoolPositionViewFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function setupPool(uint256 pid, address underlying) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (pid > store.poolCount) {
            store.poolCount = pid;
        }
        store.pools[pid].underlying = underlying;
        store.pools[pid].initialized = true;
        store.pools[pid].feeIndex = 1e18;
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = amount;
        LibAppStorage.s().pools[pid].userFeeIndex[positionKey] = 1e18;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setDirectData(bytes32 positionKey, uint256 pid, uint256 locked, uint256 lent, uint256 borrowed) external {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibEncumbrance.position(positionKey, pid).directLocked = locked;
        LibEncumbrance.position(positionKey, pid).directLent = lent;
        ds.directBorrowedPrincipal[positionKey][pid] = borrowed;
        LibDirectStorage.addBorrowerAgreement(ds, positionKey, 1);
        LibDirectStorage.addBorrowerAgreement(ds, positionKey, 2);
    }
}

contract MockPositionNFTForGas {
    function getPositionKey(uint256 tokenId) external pure returns (bytes32) {
        require(tokenId == 1, "Invalid token ID");
        return bytes32(uint256(0x1234));
    }

    function getPoolId(uint256 tokenId) external pure returns (uint256) {
        require(tokenId == 1, "Invalid token ID");
        return 1;
    }
}

contract MultiPoolPositionViewGasTest is Test {
    MultiPoolPositionViewHarness internal harness;
    PositionNFT internal nft;

    bytes32 internal positionKey;
    uint256 internal tokenId;

    address internal constant USDC = address(0x1001);
    address internal constant USDT = address(0x1002);

    function setUp() public {
        harness = new MultiPoolPositionViewHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenId = nft.mint(address(0xBEEF), 1);
        positionKey = nft.getPositionKey(tokenId);

        harness.setPositionNFT(address(nft));
        harness.setupPool(1, USDC);
        harness.setupPool(2, USDT);
        harness.setUserPrincipal(1, positionKey, 1000e6);
        harness.setUserPrincipal(2, positionKey, 500e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
        harness.setDirectData(positionKey, 1, 100e6, 200e6, 50e6);
    }

    function test_gas_GetMultiPoolPositionState() public {
        vm.resumeGasMetering();
        harness.getMultiPoolPositionState(tokenId);
    }

    function test_gas_GetPositionPoolMemberships() public {
        vm.resumeGasMetering();
        harness.getPositionPoolMemberships(tokenId);
    }

    function test_gas_GetPositionPoolData() public {
        vm.resumeGasMetering();
        harness.getPositionPoolData(tokenId, 1);
    }

    function test_gas_IsPositionMemberOfPool() public {
        vm.resumeGasMetering();
        harness.isPositionMemberOfPool(tokenId, 1);
    }

    function test_gas_GetPositionAggregatedSummary() public {
        vm.resumeGasMetering();
        harness.getPositionAggregatedSummary(tokenId);
    }

    function test_gas_GetPositionActivePools() public {
        vm.resumeGasMetering();
        harness.getPositionActivePools(tokenId);
    }

    function test_gas_GetPositionDirectSummary() public {
        vm.resumeGasMetering();
        harness.getPositionDirectSummary(tokenId);
    }

    function test_gas_GetPositionDirectAgreementIds() public {
        vm.resumeGasMetering();
        harness.getPositionDirectAgreementIds(tokenId);
    }

    function test_gas_GetPositionDirectAgreements() public {
        vm.resumeGasMetering();
        harness.getPositionDirectAgreements(tokenId);
    }

    function test_gas_GetPositionDirectSummaryByAsset() public {
        vm.resumeGasMetering();
        harness.getPositionDirectSummaryByAsset(tokenId);
    }

    function test_gas_GetPositionPoolStates() public {
        vm.resumeGasMetering();
        harness.getPositionPoolStates(tokenId);
    }

    function test_gas_GetPositionPoolDataPoolOnly() public {
        vm.resumeGasMetering();
        harness.getPositionPoolDataPoolOnly(tokenId, 1);
    }

    function test_gas_GetUserPositions() public {
        vm.resumeGasMetering();
        harness.getUserPositions(address(0xBEEF));
    }

    function test_gas_MultiPoolSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract PoolUtilizationViewHarness is PoolUtilizationViewFacet {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.isCapped = true;
        p.poolConfig.depositCap = 100 ether;
        p.poolConfig.maxUserCount = 10;
        p.totalDeposits = 50 ether;
        p.userCount = 1;
    }

    function seedUserPrincipal(uint256 pid, bytes32 key, uint256 amount) external {
        LibAppStorage.s().pools[pid].userPrincipal[key] = amount;
    }
}

contract PoolUtilizationViewGasTest is Test {
    PoolUtilizationViewHarness internal harness;
    MockERC20 internal token;
    uint256 internal constant PID = 1;
    bytes32 internal constant USER = bytes32(uint256(0xB0B));

    function setUp() public {
        harness = new PoolUtilizationViewHarness();
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);
        harness.initPool(PID, address(token));
        harness.seedUserPrincipal(PID, USER, 10 ether);
        token.mint(address(harness), 20 ether);
    }

    function test_gas_GetPoolCapacity() public {
        vm.resumeGasMetering();
        harness.getPoolCapacity(PID);
    }

    function test_gas_GetPoolStats() public {
        vm.resumeGasMetering();
        harness.getPoolStats(PID);
    }

    function test_gas_PoolUtilizationSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract PositionViewHarness is PositionViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }

    function seedFixedLoan(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 principal, uint40 expiry) external {
        Types.PoolData storage p = s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.fullInterest = 0;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = expiry;
        loan.apyBps = 1000;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = 0;
        p.activeFixedLoanCount[positionKey] = 1;
    }

    function seedRolling(uint256 pid, bytes32 positionKey, uint256 principal, uint8 missedPayments) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp - 90 days);
        loan.lastAccrualTs = uint40(block.timestamp - 90 days);
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 30 days;
        loan.depositBacked = true;
        loan.active = true;
    }

    function setFeeIndex(uint256 pid, uint256 feeIndex, bytes32 positionKey, uint256 userFeeIndex, uint256 accruedYield)
        external
    {
        Types.PoolData storage p = s().pools[pid];
        p.feeIndex = feeIndex;
        p.userFeeIndex[positionKey] = userFeeIndex;
        p.userAccruedYield[positionKey] = accruedYield;
    }

    function setDirectBorrowed(bytes32 key, uint256 pid, uint256 amount) external {
        LibDirectStorage.directStorage().directBorrowedPrincipal[key][pid] = amount;
    }

    function setDirectLocked(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directLocked = amount;
    }

    function setDirectOfferEscrow(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directOfferEscrow = amount;
    }

    function setDirectLent(bytes32 key, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(key, pid).directLent = amount;
    }

    function setIndexEncumbered(bytes32 key, uint256 pid, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(key, pid, indexId, amount);
    }
}

contract PositionViewGasTest is Test {
    PositionViewHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    address internal user = address(0xBEEF);
    uint256 internal tokenId;

    function setUp() public {
        harness = new PositionViewHarness();
        nft = new PositionNFT();
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(this));
        harness.initPool(PID, address(token));

        tokenId = nft.mint(user, PID);
        bytes32 key = nft.getPositionKey(tokenId);

        harness.seedPosition(PID, key, 100 ether);
        harness.seedFixedLoan(PID, key, 1, 10 ether, uint40(block.timestamp + 1 days));
        vm.warp(100 days);
        harness.seedRolling(PID, key, 20 ether, 1);
        harness.setDirectBorrowed(key, PID, 5 ether);
        harness.setDirectLocked(key, PID, 1 ether);
        harness.setDirectOfferEscrow(key, PID, 2 ether);
        harness.setDirectLent(key, PID, 2 ether);
        harness.setIndexEncumbered(key, PID, 1, 3 ether);
        harness.setFeeIndex(PID, LibFeeIndex.INDEX_SCALE + 1e17, key, LibFeeIndex.INDEX_SCALE, 0);
    }

    function test_gas_GetPositionState() public {
        vm.resumeGasMetering();
        harness.getPositionState(tokenId, PID);
    }

    function test_gas_GetPositionSolvency() public {
        vm.resumeGasMetering();
        harness.getPositionSolvency(tokenId, PID);
    }

    function test_gas_GetPositionLoanSummary() public {
        vm.resumeGasMetering();
        harness.getPositionLoanSummary(tokenId, PID);
    }

    function test_gas_GetPositionEncumbrance() public {
        vm.resumeGasMetering();
        harness.getPositionEncumbrance(tokenId, PID);
    }

    function test_gas_GetPositionLoanIds() public {
        vm.prank(user);
        vm.resumeGasMetering();
        harness.getPositionLoanIds(tokenId, PID, 0, 10);
    }

    function test_gas_IsPositionDelinquent() public {
        vm.resumeGasMetering();
        harness.isPositionDelinquent(tokenId, PID);
    }

    function test_gas_GetPositionMetadata() public {
        vm.resumeGasMetering();
        harness.getPositionMetadata(tokenId, PID);
    }

    function test_gas_GetLoansDetails() public {
        vm.resumeGasMetering();
        uint256[] memory loanIds = new uint256[](1);
        loanIds[0] = 1;
        harness.getLoansDetails(PID, loanIds);
    }

    function test_gas_PositionSelectors() public {
        vm.resumeGasMetering();
        harness.selectors();
    }
}

contract MaintenanceSelectorsGasTest is Test {
    MaintenanceFacet internal facet;

    function setUp() public {
        facet = new MaintenanceFacet();
    }

    function test_gas_MaintenanceSelectors() public {
        vm.resumeGasMetering();
        facet.selectors();
    }
}

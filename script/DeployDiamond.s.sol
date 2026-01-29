// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Diamond} from "../src/core/Diamond.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {DiamondCutFacet} from "../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/core/OwnershipFacet.sol";
import {AdminFacet} from "../src/admin/AdminFacet.sol";
import {MaintenanceFacet} from "../src/core/MaintenanceFacet.sol";
import {FlashLoanFacet} from "../src/equallend/FlashLoanFacet.sol";
import {FeeFacet} from "../src/core/FeeFacet.sol";
import {AdminGovernanceFacet} from "../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../src/equallend/PoolManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexViewFacetV3} from "../src/views/EqualIndexViewFacetV3.sol";
import {EqualIndexBaseV3} from "../src/equalindex/EqualIndexBaseV3.sol";
import {LiquidityViewFacet} from "../src/views/LiquidityViewFacet.sol";
import {LoanViewFacet} from "../src/views/LoanViewFacet.sol";
import {ConfigViewFacet} from "../src/views/ConfigViewFacet.sol";
import {EnhancedLoanViewFacet} from "../src/views/EnhancedLoanViewFacet.sol";
import {PoolUtilizationViewFacet} from "../src/views/PoolUtilizationViewFacet.sol";
import {LoanPreviewFacet} from "../src/views/LoanPreviewFacet.sol";
import {PositionViewFacet} from "../src/views/PositionViewFacet.sol";
import {PositionNFTMetadataFacet} from "../src/views/PositionNFTMetadataFacet.sol";
import {MultiPoolPositionViewFacet} from "../src/views/MultiPoolPositionViewFacet.sol";
import {AuctionManagementViewFacet} from "../src/views/AuctionManagementViewFacet.sol";
import {PositionManagementFacet} from "../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../src/equallend/PenaltyFacet.sol";
import {PositionNFT} from "../src/nft/PositionNFT.sol";
import {DiamondInit} from "../src/core/DiamondInit.sol";
import {EqualLendDirectOfferFacet} from "../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectAgreementFacet} from "../src/equallend-direct/EqualLendDirectAgreementFacet.sol";
import {EqualLendDirectLifecycleFacet} from "../src/equallend-direct/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "../src/equallend-direct/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "../src/equallend-direct/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "../src/equallend-direct/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "../src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol";
import {EqualLendDirectRollingViewFacet} from "../src/views/EqualLendDirectRollingViewFacet.sol";
import {EqualLendDirectViewFacet} from "../src/views/EqualLendDirectViewFacet.sol";
import {ActiveCreditViewFacet} from "../src/views/ActiveCreditViewFacet.sol";
import {AmmAuctionFacet} from "../src/EqualX/AmmAuctionFacet.sol";
import {AtomicDeskFacet} from "../src/EqualX/AtomicDeskFacet.sol";
import {MamCurveCreationFacet} from "../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../src/EqualX/MamCurveExecutionFacet.sol";
import {CommunityAuctionFacet} from "../src/EqualX/CommunityAuctionFacet.sol";
import {SettlementEscrowFacet} from "../src/EqualX/SettlementEscrowFacet.sol";
import {Mailbox} from "../src/EqualX/Mailbox.sol";
import {OptionsFacet} from "../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../src/derivatives/FuturesFacet.sol";
import {DerivativeViewFacet} from "../src/views/DerivativeViewFacet.sol";
import {MamCurveViewFacet} from "../src/views/MamCurveViewFacet.sol";
import {DirectTypes} from "../src/libraries/DirectTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Types} from "../src/libraries/Types.sol";
import {OptionToken} from "../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../src/derivatives/FuturesToken.sol";
import {PositionAgentTBAFacet} from "../src/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "../src/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "../src/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentConfigFacet} from "../src/erc6551/PositionAgentConfigFacet.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

interface IPoolManagementFacetInitConfig {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

/// @notice Example deployment script assembling the Diamond with default pool config.
contract DeployDiamondScript is Script {
    address internal owner;
    address internal timelock;
    address internal treasury;
    address internal diamondAddress;

    uint16 internal constant DEFAULT_DEPOSITOR_LTV_BPS = 7_500;
    uint16 internal constant DEFAULT_EXTERNAL_CR_BPS = 15_000;
    uint16 internal constant DEFAULT_ROLLING_APY_BPS = 600; // 6% for deposit-backed
    uint16 internal constant DEFAULT_ROLLING_APY_BPS_EXTERNAL = 400; // 4% for external collateral
    uint16 internal constant DEFAULT_MAINTENANCE_RATE_BPS = 100;
    uint16 internal constant DEFAULT_ACTIVE_CREDIT_SHARE_BPS = 2_500;
    uint8 internal constant DEFAULT_ROLLING_DELINQUENCY_EPOCHS = 2;
    uint8 internal constant DEFAULT_ROLLING_PENALTY_EPOCHS = 3;
    uint16 internal constant DEFAULT_ROLLING_MIN_PAYMENT_BPS = 0;
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_FLASH = keccak256("ACTION_FLASH");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");
    bytes32 internal constant ACTION_CLOSE_ROLLING = keccak256("ACTION_CLOSE_ROLLING");
    uint64 internal constant ATOMIC_REFUND_SAFETY_WINDOW = 3 days;
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ERC8004_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant ERC8004_SEPOLIA = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    struct TokenSpec {
        string id;
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
        bool isNative;
        bool isCapped;
        uint256 depositCap;
    }
    
    struct IndexSpec {
        string id;
        string name;
        string symbol;
        string[] assetIds;
        uint256[] bundleAmounts;
    }

    mapping(string => address) internal tokenById;
    mapping(string => uint8) internal decimalsById;

    function run() external {
        owner = vm.envAddress("OWNER");
        timelock = vm.envAddress("TIMELOCK");
        treasury = vm.envAddress("TREASURY");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        bool isGov = (deployer == owner || deployer == timelock);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Deploy facets
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        AdminFacet adminFacet = new AdminFacet();
        MaintenanceFacet maintenance = new MaintenanceFacet();
        FlashLoanFacet flash = new FlashLoanFacet();
        FeeFacet fee = new FeeFacet();
        AdminGovernanceFacet admin = new AdminGovernanceFacet();
        PoolManagementFacet poolManagement = new PoolManagementFacet();
        EqualIndexAdminFacetV3 equalIndexAdmin = new EqualIndexAdminFacetV3();
        EqualIndexActionsFacetV3 equalIndexActions = new EqualIndexActionsFacetV3();
        EqualIndexPositionFacet equalIndexPosition = new EqualIndexPositionFacet();
        EqualIndexViewFacetV3 equalIndexView = new EqualIndexViewFacetV3();
        LiquidityViewFacet liqView = new LiquidityViewFacet();
        LoanViewFacet loanView = new LoanViewFacet();
        // ConfigViewFacet selectors() intentionally omitted to avoid duplicate selector collisions.
        ConfigViewFacet cfgView = new ConfigViewFacet();
        EnhancedLoanViewFacet enhancedView = new EnhancedLoanViewFacet();
        PoolUtilizationViewFacet poolUtil = new PoolUtilizationViewFacet();
        LoanPreviewFacet loanPreview = new LoanPreviewFacet();
        PositionViewFacet positionView = new PositionViewFacet();
        PositionNFTMetadataFacet positionNftMetadata = new PositionNFTMetadataFacet();
        MultiPoolPositionViewFacet multiPoolView = new MultiPoolPositionViewFacet();
        AuctionManagementViewFacet auctionView = new AuctionManagementViewFacet();
        PositionManagementFacet positionManagement = new PositionManagementFacet();
        LendingFacet lending = new LendingFacet();
        PenaltyFacet penalty = new PenaltyFacet();
        EqualLendDirectOfferFacet directOffer = new EqualLendDirectOfferFacet();
        EqualLendDirectAgreementFacet directAgreement = new EqualLendDirectAgreementFacet();
        EqualLendDirectLifecycleFacet directLifecycle = new EqualLendDirectLifecycleFacet();
        EqualLendDirectRollingOfferFacet directRollingOffer = new EqualLendDirectRollingOfferFacet();
        EqualLendDirectRollingAgreementFacet directRollingAgreement = new EqualLendDirectRollingAgreementFacet();
        EqualLendDirectRollingLifecycleFacet directRollingLifecycle = new EqualLendDirectRollingLifecycleFacet();
        EqualLendDirectRollingPaymentFacet directRollingPayment = new EqualLendDirectRollingPaymentFacet();
        EqualLendDirectRollingViewFacet directRollingView = new EqualLendDirectRollingViewFacet();
        EqualLendDirectViewFacet directView = new EqualLendDirectViewFacet();
        ActiveCreditViewFacet activeCreditView = new ActiveCreditViewFacet();
        AmmAuctionFacet ammAuction = new AmmAuctionFacet();
        AtomicDeskFacet atomicDesk = new AtomicDeskFacet();
        MamCurveCreationFacet mamCurveCreate = new MamCurveCreationFacet();
        MamCurveManagementFacet mamCurveManage = new MamCurveManagementFacet();
        MamCurveExecutionFacet mamCurveExec = new MamCurveExecutionFacet();
        CommunityAuctionFacet communityAuction = new CommunityAuctionFacet();
        SettlementEscrowFacet settlementEscrow = new SettlementEscrowFacet();
        OptionsFacet optionsFacet = new OptionsFacet();
        FuturesFacet futuresFacet = new FuturesFacet();
        DerivativeViewFacet derivativeView = new DerivativeViewFacet();
        MamCurveViewFacet mamCurveView = new MamCurveViewFacet();
        PositionAgentTBAFacet positionAgentTBA = new PositionAgentTBAFacet();
        PositionAgentRegistryFacet positionAgentRegistry = new PositionAgentRegistryFacet();
        PositionAgentViewFacet positionAgentView = new PositionAgentViewFacet();
        PositionAgentConfigFacet positionAgentConfig = new PositionAgentConfigFacet();

        // Build facet cuts (core + admin + fee + index + base views)
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](14);
        cuts[0] = _cut(address(cut), _selectors(cut));
        cuts[1] = _cut(address(loupe), _selectors(loupe));
        cuts[2] = _cut(address(own), _selectors(own));
        cuts[3] = _cut(address(adminFacet), _selectors(adminFacet));
        cuts[4] = _cut(address(maintenance), _selectors(maintenance));
        cuts[5] = _cut(address(flash), _selectors(flash));
        cuts[6] = _cut(address(fee), _selectors(fee));
        cuts[7] = _cut(address(admin), _selectors(admin));
        cuts[8] = _cut(address(poolManagement), _selectors(poolManagement));
        cuts[9] = _cut(address(equalIndexAdmin), _selectors(equalIndexAdmin));
        cuts[10] = _cut(address(equalIndexActions), _selectors(equalIndexActions));
        cuts[11] = _cut(address(equalIndexPosition), _selectors(equalIndexPosition));
        cuts[12] = _cut(address(equalIndexView), _selectors(equalIndexView));
        cuts[13] = _cut(address(liqView), _selectors(liqView));
        // loanView, cfgView, and new view facets appended via add more selectors
        IDiamondCut.FacetCut[] memory more = new IDiamondCut.FacetCut[](37);
        more[0] = _cut(address(loanView), _selectors(loanView));
        more[1] = _cut(address(cfgView), _selectors(cfgView));
        more[2] = _cut(address(enhancedView), _selectors(enhancedView));
        more[3] = _cut(address(poolUtil), _selectors(poolUtil));
        more[4] = _cut(address(loanPreview), _selectors(loanPreview));
        more[5] = _cut(address(positionView), _selectors(positionView));
        more[6] = _cut(address(positionNftMetadata), _selectors(positionNftMetadata));
        more[7] = _cut(address(multiPoolView), _selectors(multiPoolView));
        more[8] = _cut(address(auctionView), _selectors(auctionView));
        more[9] = _cut(address(positionManagement), _selectors(positionManagement));
        more[10] = _cut(address(lending), _selectors(lending));
        more[11] = _cut(address(penalty), _selectors(penalty));
        more[12] = _cut(address(directOffer), _selectors(directOffer));
        more[13] = _cut(address(directAgreement), _selectors(directAgreement));
        more[14] = _cut(address(directLifecycle), _selectors(directLifecycle));
        more[15] = _cut(address(directView), _selectors(directView));
        more[16] = _cut(address(directRollingOffer), _selectors(directRollingOffer));
        more[17] = _cut(address(directRollingAgreement), _selectors(directRollingAgreement));
        more[18] = _cut(address(directRollingLifecycle), _selectors(directRollingLifecycle));
        more[19] = _cut(address(directRollingPayment), _selectors(directRollingPayment));
        more[20] = _cut(address(directRollingView), _selectors(directRollingView));
        more[21] = _cut(address(activeCreditView), _selectors(activeCreditView));
        more[22] = _cut(address(ammAuction), _selectors(ammAuction));
        more[23] = _cut(address(communityAuction), _selectors(communityAuction));
        more[24] = _cut(address(atomicDesk), _selectors(atomicDesk));
        more[25] = _cut(address(settlementEscrow), _selectors(settlementEscrow));
        more[26] = _cut(address(mamCurveCreate), _selectors(mamCurveCreate));
        more[27] = _cut(address(mamCurveManage), _selectors(mamCurveManage));
        more[28] = _cut(address(mamCurveExec), _selectors(mamCurveExec));
        more[29] = _cut(address(optionsFacet), _selectors(optionsFacet));
        more[30] = _cut(address(futuresFacet), _selectors(futuresFacet));
        more[31] = _cut(address(derivativeView), _selectors(derivativeView));
        more[32] = _cut(address(mamCurveView), _selectors(mamCurveView));
        more[33] = _cut(address(positionAgentTBA), _selectors(positionAgentTBA));
        more[34] = _cut(address(positionAgentRegistry), _selectors(positionAgentRegistry));
        more[35] = _cut(address(positionAgentView), _selectors(positionAgentView));
        more[36] = _cut(address(positionAgentConfig), _selectors(positionAgentConfig));

        // Deploy diamond
        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner}));
        diamondAddress = address(diamond);
        
        // Deploy PositionNFT contract
        PositionNFT nftContract = new PositionNFT();

        // Deploy derivative ERC-1155 tokens with the Diamond as manager
        OptionToken optionToken = new OptionToken("", owner, diamondAddress);
        FuturesToken futuresToken = new FuturesToken("", owner, diamondAddress);

        console2.log("OptionToken", address(optionToken));
        console2.log("FuturesToken", address(futuresToken));
        optionToken.setManager(diamondAddress);
        futuresToken.setManager(diamondAddress);
        
        // add remaining view facets and initialize timelock storage + PositionNFT
        DiamondInit initializer = new DiamondInit();
        IDiamondCut(address(diamond))
            .diamondCut(more, address(initializer), abi.encodeWithSelector(DiamondInit.init.selector, timelock, address(nftContract)));

        address erc6551Implementation = vm.envOr("ERC6551_IMPLEMENTATION", address(0));
        address identityRegistry = _resolveIdentityRegistry();
        PositionAgentConfigFacet(address(diamond)).setERC6551Registry(ERC6551_REGISTRY);
        if (erc6551Implementation != address(0)) {
            PositionAgentConfigFacet(address(diamond)).setERC6551Implementation(erc6551Implementation);
        } else {
            console2.log("ERC6551_IMPLEMENTATION not set; skipping implementation config");
        }
        if (identityRegistry != address(0)) {
            PositionAgentConfigFacet(address(diamond)).setIdentityRegistry(identityRegistry);
        } else {
            console2.log("Identity registry unknown; skipping identity config");
        }

        AdminGovernanceFacet gov = AdminGovernanceFacet(address(diamond));
        gov.setTreasury(treasury);
        gov.setTreasuryShareBps(2_000);
        gov.setActiveCreditShareBps(DEFAULT_ACTIVE_CREDIT_SHARE_BPS);
        gov.setProtocolFeeReceiver(treasury);
        gov.setIndexCreationFee(0.2 ether);
        gov.setPoolCreationFee(0.5 ether);
        gov.setActionFeeBounds(0, type(uint128).max);
        gov.setMaxMaintenanceRateBps(DEFAULT_MAINTENANCE_RATE_BPS);
        gov.setDefaultMaintenanceRateBps(DEFAULT_MAINTENANCE_RATE_BPS);
        gov.setRollingDelinquencyThresholds(
            DEFAULT_ROLLING_DELINQUENCY_EPOCHS,
            DEFAULT_ROLLING_PENALTY_EPOCHS
        );
        gov.setRollingMinPaymentBps(DEFAULT_ROLLING_MIN_PAYMENT_BPS);
        gov.setFoundationReceiver(owner);
        gov.setDefaultPoolConfig(_defaultPoolConfig(18));
        gov.setDirectRollingConfig(_defaultDirectRollingConfig());
        gov.setDerivativeFeeConfig(0, 500, 5, 10, 2, 7000, 7000, 7000, 5e18, 0, 0);

        _deployTokensAndPools(PoolManagementFacet(address(diamond)), isGov, 0.5 ether);
        _deployIndexTokens(isGov, 0.2 ether);
        EqualLendDirectViewFacet(address(diamond)).setDirectConfig(_defaultDirectConfig());
        OptionsFacet(address(diamond)).setOptionToken(address(optionToken));
        FuturesFacet(address(diamond)).setFuturesToken(address(futuresToken));
        SettlementEscrowFacet(address(diamond)).setRefundSafetyWindow(ATOMIC_REFUND_SAFETY_WINDOW);
        SettlementEscrowFacet(address(diamond)).configureAtomicDesk(address(diamond));
        Mailbox mailbox = new Mailbox(address(diamond));
        SettlementEscrowFacet(address(diamond)).configureMailbox(address(mailbox));
        SettlementEscrowFacet(address(diamond)).setCommittee(timelock, true);
        SettlementEscrowFacet(address(diamond)).transferGovernor(timelock);

        vm.stopBroadcast();
    }

    function _cut(address facet, bytes4[] memory selectors_) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors_;
    }

    function _resolveIdentityRegistry() internal view returns (address) {
        if (block.chainid == 1) {
            return ERC8004_MAINNET;
        }
        if (block.chainid == 11155111) {
            return ERC8004_SEPOLIA;
        }
        return vm.envOr("IDENTITY_REGISTRY", address(0));
    }

    // Selector helpers
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

    function _selectors(AdminFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.setTimelock.selector;
        s[1] = AdminFacet.timelock.selector;
    }

    function _selectors(MaintenanceFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = MaintenanceFacet.pokeMaintenance.selector;
        s[1] = MaintenanceFacet.settleMaintenance.selector;
    }

    function _selectors(FlashLoanFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = FlashLoanFacet.flashLoan.selector;
    }

    function _selectors(FeeFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = FeeFacet.setPoolActionFee.selector;
        s[1] = FeeFacet.setIndexActionFee.selector;
        s[2] = FeeFacet.getPoolActionFee.selector;
        s[3] = FeeFacet.getIndexActionFee.selector;
        s[4] = FeeFacet.previewActionFee.selector;
        s[5] = FeeFacet.previewIndexActionFee.selector;
        s[6] = FeeFacet.getPoolActionFees.selector;
        s[7] = FeeFacet.previewActionFees.selector;
    }

    function _selectors(AdminGovernanceFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = AdminGovernanceFacet.setDefaultPoolConfig.selector;
        s[1] = AdminGovernanceFacet.setAumFee.selector;
        s[2] = AdminGovernanceFacet.setPoolConfig.selector;
        s[3] = AdminGovernanceFacet.setRollingDelinquencyThresholds.selector;
        s[4] = AdminGovernanceFacet.setRollingMinPaymentBps.selector;
        s[5] = AdminGovernanceFacet.setPoolDeprecated.selector;
        s[6] = AdminGovernanceFacet.setFoundationReceiver.selector;
        s[7] = AdminGovernanceFacet.setDefaultMaintenanceRateBps.selector;
        s[8] = AdminGovernanceFacet.setMaxMaintenanceRateBps.selector;
        s[9] = AdminGovernanceFacet.setTreasury.selector;
        s[10] = AdminGovernanceFacet.setTreasuryShareBps.selector;
        s[11] = AdminGovernanceFacet.setActiveCreditShareBps.selector;
        s[12] = AdminGovernanceFacet.setActionFeeBounds.selector;
        s[13] = AdminGovernanceFacet.setActionFeeConfig.selector;
        s[14] = AdminGovernanceFacet.setDerivativeFeeConfig.selector;
        s[15] = AdminGovernanceFacet.setProtocolFeeReceiver.selector;
        s[16] = AdminGovernanceFacet.setIndexCreationFee.selector;
        s[17] = AdminGovernanceFacet.setPoolCreationFee.selector;
        s[18] = AdminGovernanceFacet.setPositionMintFee.selector;
        s[19] = AdminGovernanceFacet.executeDiamondCut.selector;
        s[20] = AdminGovernanceFacet.setDirectRollingConfig.selector;
    }

    function _selectors(PoolManagementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = IPoolManagementFacetInitDefault.initPool.selector;
        s[1] = IPoolManagementFacetInitConfig.initPool.selector;
        s[2] = PoolManagementFacet.initPoolWithActionFees.selector;
        s[3] = PoolManagementFacet.initManagedPool.selector;
        s[4] = PoolManagementFacet.setRollingApy.selector;
        s[5] = PoolManagementFacet.setDepositorLTV.selector;
        s[6] = PoolManagementFacet.setMinDepositAmount.selector;
        s[7] = PoolManagementFacet.setMinLoanAmount.selector;
        s[8] = PoolManagementFacet.setMinTopupAmount.selector;
        s[9] = PoolManagementFacet.setDepositCap.selector;
        s[10] = PoolManagementFacet.setIsCapped.selector;
        s[11] = PoolManagementFacet.setMaxUserCount.selector;
        s[12] = PoolManagementFacet.setMaintenanceRate.selector;
        s[13] = PoolManagementFacet.setFlashLoanFee.selector;
        s[14] = PoolManagementFacet.setActionFees.selector;
        s[15] = PoolManagementFacet.addToWhitelist.selector;
        s[16] = PoolManagementFacet.removeFromWhitelist.selector;
        s[17] = PoolManagementFacet.setWhitelistEnabled.selector;
        s[18] = PoolManagementFacet.transferManager.selector;
        s[19] = PoolManagementFacet.renounceManager.selector;
    }

    function _selectors(EqualIndexAdminFacetV3) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualIndexAdminFacetV3.createIndex.selector;
        s[1] = EqualIndexAdminFacetV3.setIndexFees.selector;
        s[2] = EqualIndexAdminFacetV3.setPaused.selector;
    }

    function _selectors(EqualIndexActionsFacetV3) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualIndexActionsFacetV3.mint.selector;
        s[1] = EqualIndexActionsFacetV3.burn.selector;
        s[2] = EqualIndexActionsFacetV3.flashLoan.selector;
    }

    function _selectors(EqualIndexPositionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualIndexPositionFacet.mintFromPosition.selector;
        s[1] = EqualIndexPositionFacet.burnFromPosition.selector;
    }

    function _selectors(EqualIndexViewFacetV3) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EqualIndexViewFacetV3.getIndex.selector;
        s[1] = EqualIndexViewFacetV3.getVaultBalance.selector;
        s[2] = EqualIndexViewFacetV3.getFeePot.selector;
        s[3] = EqualIndexViewFacetV3.getProtocolBalance.selector;
        s[4] = EqualIndexViewFacetV3.getIndexAssets.selector;
        s[5] = EqualIndexViewFacetV3.getIndexAssetCount.selector;
    }

    function _selectors(LiquidityViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(LoanViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(ConfigViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(EnhancedLoanViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PoolUtilizationViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(LoanPreviewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PositionViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PositionNFTMetadataFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(MultiPoolPositionViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(AuctionManagementViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PositionManagementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = PositionManagementFacet.mintPosition.selector;
        s[1] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[2] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
        s[3] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256)"));
        s[4] = bytes4(keccak256("rollYieldToPosition(uint256,uint256)"));
        s[5] = bytes4(keccak256("closePoolPosition(uint256,uint256)"));
        s[6] = PositionManagementFacet.cleanupMembership.selector;
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256)"));
        s[1] = bytes4(keccak256("openRollingFromPosition(uint256,uint256)"));
        s[2] = bytes4(keccak256("makePaymentFromPosition(uint256,uint256,uint256)"));
        s[3] = bytes4(keccak256("makePaymentFromPosition(uint256,uint256)"));
        s[4] = bytes4(keccak256("expandRollingFromPosition(uint256,uint256,uint256)"));
        s[5] = bytes4(keccak256("expandRollingFromPosition(uint256,uint256)"));
        s[6] = bytes4(keccak256("closeRollingCreditFromPosition(uint256,uint256)"));
        s[7] = bytes4(keccak256("closeRollingCreditFromPosition(uint256)"));
        s[8] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256)"));
        s[9] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256)"));
        s[10] = bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256,uint256)"));
        s[11] = bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256)"));
    }

    function _selectors(PenaltyFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("penalizePositionRolling(uint256,uint256,address)"));
        s[1] = bytes4(keccak256("penalizePositionRolling(uint256,address)"));
        s[2] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,uint256,address)"));
        s[3] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,address)"));
    }

    function _selectors(EqualLendDirectOfferFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = EqualLendDirectOfferFacet.postBorrowerOffer.selector;
        s[1] = EqualLendDirectOfferFacet.cancelBorrowerOffer.selector;
        s[2] = bytes4(keccak256("postOffer((uint256,uint256,uint256,address,address,uint256,uint16,uint64,uint256,bool,bool,bool))"));
        s[3] = bytes4(keccak256("postOffer((uint256,uint256,uint256,address,address,uint256,uint16,uint64,uint256,bool,bool,bool),(bool,uint256))"));
        s[4] = EqualLendDirectOfferFacet.cancelOffer.selector;
        s[5] = bytes4(keccak256("cancelOffersForPosition(bytes32)"));
        s[6] = bytes4(keccak256("cancelOffersForPosition(uint256)"));
        s[7] = EqualLendDirectOfferFacet.hasOpenOffers.selector;
        s[8] = EqualLendDirectOfferFacet.postRatioTrancheOffer.selector;
        s[9] = EqualLendDirectOfferFacet.cancelRatioTrancheOffer.selector;
        s[10] = EqualLendDirectOfferFacet.postBorrowerRatioTrancheOffer.selector;
        s[11] = EqualLendDirectOfferFacet.cancelBorrowerRatioTrancheOffer.selector;
    }

    function _selectors(EqualLendDirectAgreementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectAgreementFacet.acceptBorrowerOffer.selector;
        s[1] = EqualLendDirectAgreementFacet.acceptOffer.selector;
        s[2] = EqualLendDirectAgreementFacet.acceptRatioTrancheOffer.selector;
        s[3] = EqualLendDirectAgreementFacet.acceptBorrowerRatioTrancheOffer.selector;
    }

    function _selectors(EqualLendDirectLifecycleFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectLifecycleFacet.repay.selector;
        s[1] = EqualLendDirectLifecycleFacet.exerciseDirect.selector;
        s[2] = EqualLendDirectLifecycleFacet.recover.selector;
        s[3] = EqualLendDirectLifecycleFacet.callDirect.selector;
    }

    function _selectors(EqualLendDirectViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = EqualLendDirectViewFacet.setDirectConfig.selector;
        s[1] = EqualLendDirectViewFacet.getBorrowerOffer.selector;
        s[2] = EqualLendDirectViewFacet.getRatioTrancheOffer.selector;
        s[3] = EqualLendDirectViewFacet.getBorrowerRatioTrancheOffer.selector;
        s[4] = EqualLendDirectViewFacet.getOffer.selector;
        s[5] = EqualLendDirectViewFacet.getOfferSummary.selector;
        s[6] = EqualLendDirectViewFacet.getAgreement.selector;
        s[7] = EqualLendDirectViewFacet.getPositionDirectState.selector;
        s[8] = EqualLendDirectViewFacet.getPoolActiveDirectLent.selector;
        s[9] = EqualLendDirectViewFacet.getBorrowerAgreements.selector;
        s[10] = EqualLendDirectViewFacet.getBorrowerOffers.selector;
        s[11] = EqualLendDirectViewFacet.getLenderOffers.selector;
        s[12] = EqualLendDirectViewFacet.getRatioLenderOffers.selector;
        s[13] = EqualLendDirectViewFacet.getRatioBorrowerOffers.selector;
        s[14] = EqualLendDirectViewFacet.isTrancheOffer.selector;
        s[15] = EqualLendDirectViewFacet.fillsRemaining.selector;
        s[16] = EqualLendDirectViewFacet.isTrancheDepleted.selector;
        s[17] = EqualLendDirectViewFacet.getOfferTranche.selector;
        s[18] = EqualLendDirectViewFacet.getTrancheStatus.selector;
        s[19] = EqualLendDirectViewFacet.getRatioTrancheStatus.selector;
    }

    function _selectors(EqualLendDirectRollingOfferFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = EqualLendDirectRollingOfferFacet.postBorrowerRollingOffer.selector;
        s[1] = EqualLendDirectRollingOfferFacet.postRollingOffer.selector;
        s[2] = EqualLendDirectRollingOfferFacet.cancelRollingOffer.selector;
        s[3] = EqualLendDirectRollingOfferFacet.getRollingOffer.selector;
        s[4] = EqualLendDirectRollingOfferFacet.getRollingBorrowerOffer.selector;
    }

    function _selectors(EqualLendDirectRollingAgreementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualLendDirectRollingAgreementFacet.acceptRollingOffer.selector;
        s[1] = EqualLendDirectRollingAgreementFacet.getRollingAgreement.selector;
    }

    function _selectors(EqualLendDirectRollingLifecycleFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingLifecycleFacet.repayRollingInFull.selector;
        s[1] = EqualLendDirectRollingLifecycleFacet.exerciseRolling.selector;
        s[2] = EqualLendDirectRollingLifecycleFacet.recoverRolling.selector;
    }

    function _selectors(EqualLendDirectRollingPaymentFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = EqualLendDirectRollingPaymentFacet.makeRollingPayment.selector;
    }

    function _selectors(EqualLendDirectRollingViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingViewFacet.calculateRollingPayment.selector;
        s[1] = EqualLendDirectRollingViewFacet.getRollingStatus.selector;
        s[2] = EqualLendDirectRollingViewFacet.aggregateRollingExposure.selector;
    }

    function _selectors(ActiveCreditViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(AmmAuctionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[3] = AmmAuctionFacet.cancelAuction.selector;
        s[4] = AmmAuctionFacet.getAuction.selector;
        s[5] = AmmAuctionFacet.previewSwap.selector;
    }

    function _selectors(CommunityAuctionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = CommunityAuctionFacet.createCommunityAuction.selector;
        s[1] = CommunityAuctionFacet.joinCommunityAuction.selector;
        s[2] = CommunityAuctionFacet.leaveCommunityAuction.selector;
        s[3] = CommunityAuctionFacet.claimFees.selector;
        s[4] = CommunityAuctionFacet.swapExactIn.selector;
        s[5] = CommunityAuctionFacet.finalizeAuction.selector;
        s[6] = CommunityAuctionFacet.cancelCommunityAuction.selector;
        s[7] = CommunityAuctionFacet.getCommunityAuction.selector;
        s[8] = CommunityAuctionFacet.getMakerShare.selector;
        s[9] = CommunityAuctionFacet.previewJoin.selector;
        s[10] = CommunityAuctionFacet.previewLeave.selector;
        s[11] = CommunityAuctionFacet.getTotalMakers.selector;
    }

    function _selectors(AtomicDeskFacet) internal pure returns (bytes4[] memory s) {
        // setHashlock/getReservation are wired to SettlementEscrowFacet to avoid selector collisions.
        s = new bytes4[](14);
        s[0] = AtomicDeskFacet.setAtomicPaused.selector;
        s[1] = AtomicDeskFacet.registerDesk.selector;
        s[2] = AtomicDeskFacet.setDeskStatus.selector;
        s[3] = AtomicDeskFacet.openTranche.selector;
        s[4] = AtomicDeskFacet.setTrancheStatus.selector;
        s[5] = AtomicDeskFacet.getTranche.selector;
        s[6] = AtomicDeskFacet.reserveFromTranche.selector;
        s[7] = AtomicDeskFacet.getReservationTranche.selector;
        s[8] = AtomicDeskFacet.openTakerTranche.selector;
        s[9] = AtomicDeskFacet.setTakerTrancheStatus.selector;
        s[10] = AtomicDeskFacet.getTakerTranche.selector;
        s[11] = AtomicDeskFacet.reserveFromTakerTranche.selector;
        s[12] = AtomicDeskFacet.setTakerTranchePostingFee.selector;
        s[13] = AtomicDeskFacet.reserveAtomicSwap.selector;
    }

    function _selectors(SettlementEscrowFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = SettlementEscrowFacet.setHashlock.selector;
        s[1] = SettlementEscrowFacet.settle.selector;
        s[2] = SettlementEscrowFacet.refund.selector;
        s[3] = SettlementEscrowFacet.getReservation.selector;
        s[4] = SettlementEscrowFacet.setCommittee.selector;
        s[5] = SettlementEscrowFacet.configureMailbox.selector;
        s[6] = SettlementEscrowFacet.configureAtomicDesk.selector;
        s[7] = SettlementEscrowFacet.transferGovernor.selector;
        s[8] = SettlementEscrowFacet.setRefundSafetyWindow.selector;
        s[9] = SettlementEscrowFacet.refundSafetyWindow.selector;
        s[10] = SettlementEscrowFacet.committee.selector;
        s[11] = SettlementEscrowFacet.governor.selector;
        s[12] = SettlementEscrowFacet.mailbox.selector;
        s[13] = SettlementEscrowFacet.atomicDesk.selector;
    }

    function _selectors(MamCurveCreationFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = MamCurveCreationFacet.setMamPaused.selector;
        s[1] = MamCurveCreationFacet.createCurve.selector;
        s[2] = MamCurveCreationFacet.createCurvesBatch.selector;
    }

    function _selectors(MamCurveManagementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = MamCurveManagementFacet.updateCurve.selector;
        s[1] = MamCurveManagementFacet.updateCurvesBatch.selector;
        s[2] = MamCurveManagementFacet.cancelCurve.selector;
        s[3] = MamCurveManagementFacet.cancelCurvesBatch.selector;
        s[4] = MamCurveManagementFacet.expireCurve.selector;
        s[5] = MamCurveManagementFacet.expireCurvesBatch.selector;
    }

    function _selectors(MamCurveExecutionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = MamCurveExecutionFacet.loadCurveForFill.selector;
        s[1] = MamCurveExecutionFacet.executeCurveSwap.selector;
    }

    function _selectors(OptionsFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = OptionsFacet.setOptionToken.selector;
        s[1] = OptionsFacet.setOptionsPaused.selector;
        s[2] = OptionsFacet.createOptionSeries.selector;
        s[3] = OptionsFacet.exerciseOptions.selector;
        s[4] = OptionsFacet.exerciseOptionsFor.selector;
        s[5] = OptionsFacet.reclaimOptions.selector;
    }

    function _selectors(FuturesFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = FuturesFacet.setFuturesToken.selector;
        s[1] = FuturesFacet.setFuturesPaused.selector;
        s[2] = FuturesFacet.createFuturesSeries.selector;
        s[3] = FuturesFacet.settleFutures.selector;
        s[4] = FuturesFacet.settleFuturesFor.selector;
        s[5] = FuturesFacet.reclaimFutures.selector;
    }

    function _selectors(DerivativeViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(MamCurveViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PositionAgentTBAFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = PositionAgentTBAFacet.computeTBAAddress.selector;
        s[1] = PositionAgentTBAFacet.deployTBA.selector;
        s[2] = PositionAgentTBAFacet.getTBAImplementation.selector;
        s[3] = PositionAgentTBAFacet.getERC6551Registry.selector;
    }

    function _selectors(PositionAgentRegistryFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PositionAgentRegistryFacet.recordAgentRegistration.selector;
        s[1] = PositionAgentRegistryFacet.getIdentityRegistry.selector;
    }

    function _selectors(PositionAgentViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PositionAgentViewFacet.getTBAAddress.selector;
        s[1] = PositionAgentViewFacet.getAgentId.selector;
        s[2] = PositionAgentViewFacet.isAgentRegistered.selector;
        s[3] = PositionAgentViewFacet.isTBADeployed.selector;
        s[4] = PositionAgentViewFacet.getCanonicalRegistries.selector;
        s[5] = PositionAgentViewFacet.getTBAInterfaceSupport.selector;
    }

    function _selectors(PositionAgentConfigFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionAgentConfigFacet.setERC6551Registry.selector;
        s[1] = PositionAgentConfigFacet.setERC6551Implementation.selector;
        s[2] = PositionAgentConfigFacet.setIdentityRegistry.selector;
    }

    function _deployTokensAndPools(
        PoolManagementFacet poolManagement,
        bool isGov,
        uint256 poolCreationFee
    ) internal {
        TokenSpec[] memory specs = _tokenSpecs();
        uint256 pid = 1;
        for (uint256 i; i < specs.length; i++) {
            TokenSpec memory spec = specs[i];
            address underlying;
            if (spec.isNative) {
                underlying = address(0);
            } else {
                MockERC20 token = new MockERC20(spec.name, spec.symbol, spec.decimals, spec.initialSupply);
                underlying = address(token);
            }
            // Set reasonable minimum thresholds based on decimals
            uint256 minDeposit = 10 ** spec.decimals / 100; // 0.01 tokens
            uint256 minLoan = 10 ** spec.decimals / 50; // 0.02 tokens
            uint256 minTopup = 10 ** spec.decimals / 100; // 0.01 tokens
            
            Types.PoolConfig memory config;
            config.rollingApyBps = 500; // 5% APY for deposit-backed rolling loans
            config.depositorLTVBps = 9500; // 95% LTV for deposit-backed borrowing
            config.maintenanceRateBps = 100; // 1% annual maintenance fee
            config.flashLoanFeeBps = 9; // 0.09% flash loan fee
            config.flashLoanAntiSplit = true;
            config.minDepositAmount = minDeposit;
            config.minLoanAmount = minLoan;
            config.minTopupAmount = minTopup;
            config.isCapped = spec.isCapped;
            config.depositCap = spec.depositCap;
            config.maxUserCount = 0; // Unlimited users
            config.aumFeeMinBps = 0;
            config.aumFeeMaxBps = 500; // 5% max
            config.fixedTermConfigs = _fixedTermConfigs(spec.decimals);
            
            // Create action fee set for this token
            Types.ActionFeeSet memory actionFees = _createActionFeeSet(spec.decimals);
            
            // Initialize pool with action fees
            if (isGov) {
                poolManagement.initPoolWithActionFees(pid, underlying, config, actionFees);
            } else {
                poolManagement.initPoolWithActionFees{value: poolCreationFee}(
                    pid,
                    underlying,
                    config,
                    actionFees
                );
            }

            // Track token metadata for index creation
            tokenById[spec.id] = underlying;
            decimalsById[spec.id] = spec.decimals;
            
            // Configure pool-specific settings (if any)
            _configurePool(pid, spec.decimals);
            console2.log("Initialized pool pid", pid);
            console2.log("Token address", underlying);
            console2.log("Token symbol", spec.symbol);
            pid++;
        }
    }

    function _configurePool(uint256 pid, uint8 decimals) internal {
        // Action fees are now set during pool creation in _deployTokensAndPools
        // This function is kept for any additional post-creation configuration
    }

    function _deployIndexTokens(bool isGov, uint256 indexCreationFee) internal {
        IndexSpec[] memory specs = _indexSpecs();
        EqualIndexAdminFacetV3 indexRouter = EqualIndexAdminFacetV3(diamondAddress);

        for (uint256 i; i < specs.length; i++) {
            IndexSpec memory spec = specs[i];
            uint256 len = spec.assetIds.length;
            address[] memory assets = new address[](len);
            require(spec.bundleAmounts.length == len, "bundle length mismatch");
            uint256[] memory bundleAmounts = new uint256[](len);
            uint16[] memory mintFeeBps = new uint16[](len);
            uint16[] memory burnFeeBps = new uint16[](len);

            for (uint256 j; j < len; j++) {
                string memory assetId = spec.assetIds[j];
                address asset = tokenById[assetId];
                uint8 dec = decimalsById[assetId];
                require(asset != address(0), "Index asset not deployed");
                require(dec > 0, "Index asset decimals unset");
                assets[j] = asset;
                bundleAmounts[j] = spec.bundleAmounts[j];
                mintFeeBps[j] = 150;
                burnFeeBps[j] = 250;
            }

            EqualIndexBaseV3.CreateIndexParams memory params = EqualIndexBaseV3.CreateIndexParams({
                name: spec.name,
                symbol: spec.symbol,
                assets: assets,
                bundleAmounts: bundleAmounts,
                mintFeeBps: mintFeeBps,
                burnFeeBps: burnFeeBps,
                flashFeeBps: 90
            });

            if (isGov) {
                (uint256 indexId, address token) = indexRouter.createIndex(params);
                console2.log("Created index id", spec.id);
                console2.log("indexId", indexId);
                console2.log("index token", token);
            } else {
                (uint256 indexId, address token) = indexRouter.createIndex{value: indexCreationFee}(params);
                console2.log("Created index id", spec.id);
                console2.log("indexId", indexId);
                console2.log("index token", token);
            }
        }
    }
    
    /// @notice Create action fee set for pool creation
    function _createActionFeeSet(uint8 decimals) internal pure returns (Types.ActionFeeSet memory) {
        uint128 unit = uint128(_unit(decimals));
        
        return Types.ActionFeeSet({
            borrowFee: Types.ActionFeeConfig(unit / 1000, true),      // 0.001 tokens
            repayFee: Types.ActionFeeConfig(unit / 2000, true),       // 0.0005 tokens
            withdrawFee: Types.ActionFeeConfig(unit / 2000, true),    // 0.0005 tokens
            flashFee: Types.ActionFeeConfig(unit / 5000, true),       // 0.0002 tokens
            closeRollingFee: Types.ActionFeeConfig(unit / 1000, true) // 0.001 tokens
        });
    }

    function _defaultPoolConfig(uint8 decimals) internal pure returns (Types.PoolConfig memory config) {
        uint256 minDeposit = 10 ** decimals / 100;
        uint256 minLoan = 10 ** decimals / 50;
        uint256 minTopup = 10 ** decimals / 100;
        config = _basePoolConfig(minDeposit, minLoan, minTopup, decimals);

        Types.ActionFeeSet memory actionFees = _createActionFeeSet(decimals);
        config.borrowFee = actionFees.borrowFee;
        config.repayFee = actionFees.repayFee;
        config.withdrawFee = actionFees.withdrawFee;
        config.flashFee = actionFees.flashFee;
        config.closeRollingFee = actionFees.closeRollingFee;
    }

    function _basePoolConfig(
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint8 decimals
    ) internal pure returns (Types.PoolConfig memory config) {
        config.rollingApyBps = 500;
        config.depositorLTVBps = 9500;
        config.maintenanceRateBps = 100;
        config.flashLoanFeeBps = 9;
        config.flashLoanAntiSplit = true;
        config.minDepositAmount = minDeposit;
        config.minLoanAmount = minLoan;
        config.minTopupAmount = minTopup;
        config.isCapped = false;
        config.depositCap = 0;
        config.maxUserCount = 0;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 500;
        config.fixedTermConfigs = _fixedTermConfigs(decimals);
    }

    function _tokenSpecs() internal pure returns (TokenSpec[] memory specs) {
        specs = new TokenSpec[](6);
        specs[0] = TokenSpec({
            id: "rETH",
            name: "Rocket Pool ETH",
            symbol: "rETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isNative: false,
            isCapped: false,
            depositCap: 0
        });
        specs[1] = TokenSpec({
            id: "stETH",
            name: "Lido Staked ETH",
            symbol: "stETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isNative: false,
            isCapped: false,
            depositCap: 0
        });
        specs[2] = TokenSpec({
            id: "WBTC",
            name: "Wrapped Bitcoin",
            symbol: "WBTC",
            decimals: 8,
            initialSupply: 10_000_000 * 1e8,
            isNative: false,
            isCapped: false,
            depositCap: 0
        });
        specs[3] = TokenSpec({
            id: "ETH/WETH",
            name: "Wrapped Ether",
            symbol: "WETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isNative: false,
            isCapped: false,
            depositCap: 0
        });
        specs[4] = TokenSpec({
            id: "USDC",
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            initialSupply: 10_000_000 * 1e6,
            isNative: false,
            isCapped: false,
            depositCap: 0
        });
        specs[5] = TokenSpec({
            id: "ETH",
            name: "Native ETH",
            symbol: "ETH",
            decimals: 18,
            initialSupply: 0,
            isNative: true,
            isCapped: false,
            depositCap: 0
        });
    }
    
    function _indexSpecs() internal pure returns (IndexSpec[] memory specs) {
        specs = new IndexSpec[](3);

        string[] memory ethAssets = new string[](2);
        ethAssets[0] = "rETH";
        ethAssets[1] = "stETH";
        uint256[] memory ethBundles = new uint256[](2);
        ethBundles[0] = _bundle(18, 5, 1000); // 0.005 rETH
        ethBundles[1] = _bundle(18, 5, 1000); // 0.005 stETH
        specs[0] = IndexSpec({
            id: "EQ-ETH",
            name: "EqualIndex rETH-stETH",
            symbol: "EQrstETH",
            assetIds: ethAssets,
            bundleAmounts: ethBundles
        });

        string[] memory btcAssets = new string[](2);
        btcAssets[0] = "WBTC";
        btcAssets[1] = "ETH/WETH";
        uint256[] memory btcBundles = new uint256[](2);
        btcBundles[0] = _bundle(8, 5, 1000); // 0.005 WBTC
        btcBundles[1] = _bundle(18, 5, 100); // 0.05 WETH
        specs[1] = IndexSpec({
            id: "EQ-BTC",
            name: "EqualIndex WBTC-WETH",
            symbol: "EQBTCETH",
            assetIds: btcAssets,
            bundleAmounts: btcBundles
        });

        string[] memory usdAssets = new string[](1);
        usdAssets[0] = "USDC";
        uint256[] memory usdBundles = new uint256[](1);
        usdBundles[0] = _bundle(6, 100, 1); // 100 USDC
        specs[2] = IndexSpec({
            id: "EQ-USD",
            name: "EqualIndex USDC",
            symbol: "EQmUSDC",
            assetIds: usdAssets,
            bundleAmounts: usdBundles
        });
    }

    function _fixedTermConfigs(uint8 decimals) internal pure returns (Types.FixedTermConfig[] memory configs) {
        configs = new Types.FixedTermConfig[](4);
        configs[0] = Types.FixedTermConfig({durationSecs: 30 days, apyBps: 1_000});
        configs[1] = Types.FixedTermConfig({durationSecs: 90 days, apyBps: 750});
        configs[2] = Types.FixedTermConfig({durationSecs: 180 days, apyBps: 600});
        configs[3] = Types.FixedTermConfig({durationSecs: 365 days, apyBps: 400});
    }

    function _unit(uint8 decimals) internal pure returns (uint256) {
        return 10 ** uint256(decimals);
    }

    function _bundle(uint8 decimals, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return (_unit(decimals) * numerator) / denominator;
    }

    function _defaultDirectConfig() internal pure returns (DirectTypes.DirectConfig memory cfg) {
        cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500, // 5%
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
    }

    function _defaultDirectRollingConfig() internal pure returns (DirectTypes.DirectRollingConfig memory cfg) {
        cfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 1 days,
            maxPaymentCount: 3,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 25,
            maxRollingApyBps: 5_000,
            defaultPenaltyBps: 500,
            minPaymentBps: 50
        });
    }
}

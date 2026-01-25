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
import {AdminGovernanceFacet} from "../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../src/equallend/PoolManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexViewFacetV3} from "../src/views/EqualIndexViewFacetV3.sol";
import {EqualIndexBaseV3} from "../src/equalindex/EqualIndexBaseV3.sol";
import {ConfigViewFacet} from "../src/views/ConfigViewFacet.sol";
import {PositionViewFacet} from "../src/views/PositionViewFacet.sol";
import {PositionNFTMetadataFacet} from "../src/views/PositionNFTMetadataFacet.sol";
import {MultiPoolPositionViewFacet} from "../src/views/MultiPoolPositionViewFacet.sol";
import {PositionManagementFacet} from "../src/equallend/PositionManagementFacet.sol";
import {ActiveCreditViewFacet} from "../src/views/ActiveCreditViewFacet.sol";
import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../src/equallend/PenaltyFacet.sol";
import {AmmAuctionFacet} from "../src/EqualX/AmmAuctionFacet.sol";
import {MamCurveCreationFacet} from "../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../src/EqualX/MamCurveExecutionFacet.sol";
import {CommunityAuctionFacet} from "../src/EqualX/CommunityAuctionFacet.sol";
import {MamCurveViewFacet} from "../src/views/MamCurveViewFacet.sol";
import {AuctionManagementViewFacet} from "../src/views/AuctionManagementViewFacet.sol";
import {PositionNFT} from "../src/nft/PositionNFT.sol";
import {DiamondInit} from "../src/core/DiamondInit.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Types} from "../src/libraries/Types.sol";
import {EqualLendDirectOfferFacet} from "../src/equallend-direct/EqualLendDirectOfferFacet.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

interface IPoolManagementFacetInitConfig {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

/// @notice Lean deployment script for EqualIndex, AMM auctions, MAM curves, and self-secured lending.
contract LeanDeployScript is Script {
    address internal owner;
    address internal timelock;
    address internal treasury;
    address internal diamondAddress;

    uint16 internal constant DEFAULT_MAINTENANCE_RATE_BPS = 100;
    uint16 internal constant DEFAULT_ACTIVE_CREDIT_SHARE_BPS = 2_500;
    uint16 internal constant DEFAULT_DERIVATIVE_MIN_FEE_BPS = 0;
    uint16 internal constant DEFAULT_DERIVATIVE_MAX_FEE_BPS = 1_000;
    uint16 internal constant DEFAULT_DERIVATIVE_CREATE_FEE_BPS = 30;
    uint16 internal constant DEFAULT_DERIVATIVE_EXERCISE_FEE_BPS = 30;
    uint16 internal constant DEFAULT_DERIVATIVE_RECLAIM_FEE_BPS = 30;
    uint16 internal constant DEFAULT_AMM_MAKER_SHARE_BPS = 2_000;
    uint16 internal constant DEFAULT_COMMUNITY_MAKER_SHARE_BPS = 2_000;
    uint16 internal constant DEFAULT_MAM_MAKER_SHARE_BPS = 2_000;
    uint128 internal constant DEFAULT_DERIVATIVE_CREATE_FEE_FLAT_WAD = 0;
    uint128 internal constant DEFAULT_DERIVATIVE_EXERCISE_FEE_FLAT_WAD = 0;
    uint128 internal constant DEFAULT_DERIVATIVE_RECLAIM_FEE_FLAT_WAD = 0;

    struct TokenSpec {
        string id;
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
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

    struct Deployment {
        address diamond;
        address positionNFT;
        address[] tokens;
        address[] indexTokens;
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
        Deployment memory deployment = _deploy(isGov);
        vm.stopBroadcast();

        console2.log("Diamond", deployment.diamond);
        console2.log("PositionNFT", deployment.positionNFT);
        for (uint256 i; i < deployment.tokens.length; i++) {
            console2.log("Token", deployment.tokens[i]);
        }
        for (uint256 i; i < deployment.indexTokens.length; i++) {
            console2.log("IndexToken", deployment.indexTokens[i]);
        }
    }

    function deployForTest(address owner_, address timelock_, address treasury_)
        external
        returns (Deployment memory deployment)
    {
        owner = owner_;
        timelock = timelock_;
        treasury = treasury_;
        vm.startPrank(owner_);
        deployment = _deploy(true);
        vm.stopPrank();
    }

    function _deploy(bool isGov) internal returns (Deployment memory deployment) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        AdminFacet adminFacet = new AdminFacet();
        MaintenanceFacet maintenance = new MaintenanceFacet();
        AdminGovernanceFacet admin = new AdminGovernanceFacet();
        PoolManagementFacet poolManagement = new PoolManagementFacet();
        EqualIndexAdminFacetV3 equalIndexAdmin = new EqualIndexAdminFacetV3();
        EqualIndexActionsFacetV3 equalIndexActions = new EqualIndexActionsFacetV3();
        EqualIndexPositionFacet equalIndexPosition = new EqualIndexPositionFacet();
        EqualIndexViewFacetV3 equalIndexView = new EqualIndexViewFacetV3();
        ConfigViewFacet cfgView = new ConfigViewFacet();
        PositionViewFacet positionView = new PositionViewFacet();
        PositionNFTMetadataFacet positionNftMetadata = new PositionNFTMetadataFacet();
        MultiPoolPositionViewFacet multiPoolView = new MultiPoolPositionViewFacet();
        AuctionManagementViewFacet auctionView = new AuctionManagementViewFacet();
        PositionManagementFacet positionManagement = new PositionManagementFacet();
        LendingFacet lending = new LendingFacet();
        PenaltyFacet penalty = new PenaltyFacet();
        AmmAuctionFacet ammAuction = new AmmAuctionFacet();
        MamCurveCreationFacet mamCurveCreate = new MamCurveCreationFacet();
        MamCurveManagementFacet mamCurveManage = new MamCurveManagementFacet();
        MamCurveExecutionFacet mamCurveExec = new MamCurveExecutionFacet();
        CommunityAuctionFacet communityAuction = new CommunityAuctionFacet();
        MamCurveViewFacet mamCurveView = new MamCurveViewFacet();
        ActiveCreditViewFacet activeCreditView = new ActiveCreditViewFacet();
        EqualLendDirectOfferFacet directOffers = new EqualLendDirectOfferFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](26);
        cuts[0] = _cut(address(cut), _selectors(cut));
        cuts[1] = _cut(address(loupe), _selectors(loupe));
        cuts[2] = _cut(address(own), _selectors(own));
        cuts[3] = _cut(address(adminFacet), _selectors(adminFacet));
        cuts[4] = _cut(address(maintenance), _selectors(maintenance));
        cuts[5] = _cut(address(admin), _selectors(admin));
        cuts[6] = _cut(address(poolManagement), _selectors(poolManagement));
        cuts[7] = _cut(address(equalIndexAdmin), _selectors(equalIndexAdmin));
        cuts[8] = _cut(address(equalIndexActions), _selectors(equalIndexActions));
        cuts[9] = _cut(address(equalIndexPosition), _selectors(equalIndexPosition));
        cuts[10] = _cut(address(equalIndexView), _selectors(equalIndexView));
        cuts[11] = _cut(address(cfgView), _selectors(cfgView));
        cuts[12] = _cut(address(positionView), _selectors(positionView));
        cuts[13] = _cut(address(positionNftMetadata), _selectors(positionNftMetadata));
        cuts[14] = _cut(address(multiPoolView), _selectors(multiPoolView));
        cuts[15] = _cut(address(auctionView), _selectors(auctionView));
        cuts[16] = _cut(address(positionManagement), _selectors(positionManagement));
        cuts[17] = _cut(address(lending), _selectors(lending));
        cuts[18] = _cut(address(penalty), _selectors(penalty));
        cuts[19] = _cut(address(ammAuction), _selectors(ammAuction));
        cuts[20] = _cut(address(communityAuction), _selectors(communityAuction));
        cuts[21] = _cut(address(mamCurveCreate), _selectors(mamCurveCreate));
        cuts[22] = _cut(address(mamCurveManage), _selectors(mamCurveManage));
        cuts[23] = _cut(address(mamCurveExec), _selectors(mamCurveExec));
        cuts[24] = _cut(address(activeCreditView), _selectors(activeCreditView));
        cuts[25] = _cut(address(directOffers), _selectors(directOffers));

        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner}));
        diamondAddress = address(diamond);

        PositionNFT nftContract = new PositionNFT();
        DiamondInit initializer = new DiamondInit();
        IDiamondCut(address(diamond))
            .diamondCut(
                new IDiamondCut.FacetCut[](0),
                address(initializer),
                abi.encodeWithSelector(DiamondInit.init.selector, timelock, address(nftContract))
            );

        IDiamondCut(address(diamond))
            .diamondCut(_mamViewCut(mamCurveView), address(0), "");

        AdminGovernanceFacet gov = AdminGovernanceFacet(address(diamond));
        gov.setTreasury(treasury);
        gov.setTreasuryShareBps(2_000);
        gov.setActiveCreditShareBps(DEFAULT_ACTIVE_CREDIT_SHARE_BPS);
        gov.setProtocolFeeReceiver(treasury);
        gov.setIndexCreationFee(0.2 ether);
        gov.setPoolCreationFee(0.5 ether);
        gov.setActionFeeBounds(0, type(uint128).max);
        gov.setDerivativeFeeConfig(
            DEFAULT_DERIVATIVE_MIN_FEE_BPS,
            DEFAULT_DERIVATIVE_MAX_FEE_BPS,
            DEFAULT_DERIVATIVE_CREATE_FEE_BPS,
            DEFAULT_DERIVATIVE_EXERCISE_FEE_BPS,
            DEFAULT_DERIVATIVE_RECLAIM_FEE_BPS,
            DEFAULT_AMM_MAKER_SHARE_BPS,
            DEFAULT_COMMUNITY_MAKER_SHARE_BPS,
            DEFAULT_MAM_MAKER_SHARE_BPS,
            DEFAULT_DERIVATIVE_CREATE_FEE_FLAT_WAD,
            DEFAULT_DERIVATIVE_EXERCISE_FEE_FLAT_WAD,
            DEFAULT_DERIVATIVE_RECLAIM_FEE_FLAT_WAD
        );
        gov.setMaxMaintenanceRateBps(DEFAULT_MAINTENANCE_RATE_BPS);
        gov.setDefaultMaintenanceRateBps(DEFAULT_MAINTENANCE_RATE_BPS);
        gov.setFoundationReceiver(owner);
        gov.setDefaultPoolConfig(_defaultPoolConfig(18));

        address[] memory tokens = _deployTokensAndPools(PoolManagementFacet(address(diamond)), isGov, 0.5 ether);
        address[] memory indexTokens = _deployIndexTokens(isGov, 0.2 ether);

        deployment = Deployment({
            diamond: address(diamond),
            positionNFT: address(nftContract),
            tokens: tokens,
            indexTokens: indexTokens
        });
    }

    function _mamViewCut(MamCurveViewFacet viewFacet)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(viewFacet), viewFacet.selectors());
    }

    function _cut(address facet, bytes4[] memory selectors_) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors_;
    }

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

    function _selectors(ConfigViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
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

    function _selectors(ActiveCreditViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
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

    function _selectors(AmmAuctionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[3] = AmmAuctionFacet.cancelAuction.selector;
        s[4] = AmmAuctionFacet.getAuction.selector;
        s[5] = AmmAuctionFacet.previewSwap.selector;
        s[6] = AmmAuctionFacet.getAuctionFees.selector;
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

    function _selectors(EqualLendDirectOfferFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("cancelOffersForPosition(bytes32)"));
        s[1] = EqualLendDirectOfferFacet.hasOpenOffers.selector;
    }

    function _deployTokensAndPools(
        PoolManagementFacet poolManagement,
        bool isGov,
        uint256 poolCreationFee
    ) internal returns (address[] memory tokens) {
        TokenSpec[] memory specs = _tokenSpecs();
        tokens = new address[](specs.length);
        uint256 pid = 1;
        for (uint256 i; i < specs.length; i++) {
            TokenSpec memory spec = specs[i];
            MockERC20 token = new MockERC20(spec.name, spec.symbol, spec.decimals, spec.initialSupply);
            uint256 minDeposit = 10 ** spec.decimals / 100;
            uint256 minLoan = 10 ** spec.decimals / 50;
            uint256 minTopup = 10 ** spec.decimals / 100;

            Types.PoolConfig memory config = _basePoolConfig(minDeposit, minLoan, minTopup);
            Types.ActionFeeSet memory actionFees = _createActionFeeSet(spec.decimals);
            config.isCapped = spec.isCapped;
            config.depositCap = spec.depositCap;

            if (isGov) {
                poolManagement.initPoolWithActionFees(pid, address(token), config, actionFees);
            } else {
                poolManagement.initPoolWithActionFees{value: poolCreationFee}(
                    pid,
                    address(token),
                    config,
                    actionFees
                );
            }

            tokenById[spec.id] = address(token);
            decimalsById[spec.id] = spec.decimals;
            tokens[i] = address(token);
            pid++;
        }
    }

    function _deployIndexTokens(bool isGov, uint256 indexCreationFee)
        internal
        returns (address[] memory indexTokens)
    {
        IndexSpec[] memory specs = _indexSpecs();
        indexTokens = new address[](specs.length);
        EqualIndexAdminFacetV3 indexRouter = EqualIndexAdminFacetV3(diamondAddress);

        for (uint256 i; i < specs.length; i++) {
            IndexSpec memory spec = specs[i];
            uint256 len = spec.assetIds.length;
            address[] memory assets = new address[](len);
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
                indexTokens[indexId] = token;
            } else {
                (uint256 indexId, address token) = indexRouter.createIndex{value: indexCreationFee}(params);
                indexTokens[indexId] = token;
            }
        }
    }

    function _createActionFeeSet(uint8 decimals) internal pure returns (Types.ActionFeeSet memory) {
        uint128 unit = uint128(_unit(decimals));
        return Types.ActionFeeSet({
            borrowFee: Types.ActionFeeConfig(unit / 1000, true),
            repayFee: Types.ActionFeeConfig(unit / 2000, true),
            withdrawFee: Types.ActionFeeConfig(unit / 2000, true),
            flashFee: Types.ActionFeeConfig(unit / 5000, true),
            closeRollingFee: Types.ActionFeeConfig(unit / 1000, true)
        });
    }

    function _defaultPoolConfig(uint8 decimals) internal pure returns (Types.PoolConfig memory config) {
        uint256 minDeposit = 10 ** decimals / 100;
        uint256 minLoan = 10 ** decimals / 50;
        uint256 minTopup = 10 ** decimals / 100;
        config = _basePoolConfig(minDeposit, minLoan, minTopup);

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
        uint256 minTopup
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
        config.fixedTermConfigs = _fixedTermConfigs();
    }

    function _tokenSpecs() internal pure returns (TokenSpec[] memory specs) {
        specs = new TokenSpec[](5);
        specs[0] = TokenSpec({
            id: "rETH",
            name: "Rocket Pool ETH",
            symbol: "rETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isCapped: false,
            depositCap: 0
        });
        specs[1] = TokenSpec({
            id: "stETH",
            name: "Lido Staked ETH",
            symbol: "stETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isCapped: false,
            depositCap: 0
        });
        specs[2] = TokenSpec({
            id: "WBTC",
            name: "Wrapped Bitcoin",
            symbol: "WBTC",
            decimals: 8,
            initialSupply: 10_000_000 * 1e8,
            isCapped: false,
            depositCap: 0
        });
        specs[3] = TokenSpec({
            id: "ETH/WETH",
            name: "Wrapped Ether",
            symbol: "WETH",
            decimals: 18,
            initialSupply: 10_000_000 ether,
            isCapped: false,
            depositCap: 0
        });
        specs[4] = TokenSpec({
            id: "USDC",
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            initialSupply: 10_000_000 * 1e6,
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
        ethBundles[0] = _bundle(18, 5, 1000);
        ethBundles[1] = _bundle(18, 5, 1000);
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
        btcBundles[0] = _bundle(8, 5, 1000);
        btcBundles[1] = _bundle(18, 5, 100);
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
        usdBundles[0] = _bundle(6, 100, 1);
        specs[2] = IndexSpec({
            id: "EQ-USD",
            name: "EqualIndex USDC",
            symbol: "EQmUSDC",
            assetIds: usdAssets,
            bundleAmounts: usdBundles
        });
    }

    function _fixedTermConfigs() internal pure returns (Types.FixedTermConfig[] memory configs) {
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
}

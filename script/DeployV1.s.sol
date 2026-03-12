// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Diamond} from "../src/core/Diamond.sol";
import {DiamondCutFacet} from "../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/core/OwnershipFacet.sol";
import {DiamondInit} from "../src/core/DiamondInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {PositionNFT} from "../src/nft/PositionNFT.sol";

import {AdminFacet} from "../src/admin/AdminFacet.sol";
import {PointsAdminFacet} from "../src/admin/PointsAdminFacet.sol";
import {PointsRedemptionFacet} from "../src/points/PointsRedemptionFacet.sol";
import {MaintenanceFacet} from "../src/core/MaintenanceFacet.sol";
import {AdminGovernanceFacet} from "../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../src/equallend/PoolManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexLendingFacet} from "../src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexViewFacetV3} from "../src/views/EqualIndexViewFacetV3.sol";
import {LiquidityViewFacet} from "../src/views/LiquidityViewFacet.sol";
import {LoanViewFacet} from "../src/views/LoanViewFacet.sol";
import {ConfigViewFacet} from "../src/views/ConfigViewFacet.sol";
import {PoolUtilizationViewFacet} from "../src/views/PoolUtilizationViewFacet.sol";
import {LoanPreviewFacet} from "../src/views/LoanPreviewFacet.sol";
import {PositionViewFacet} from "../src/views/PositionViewFacet.sol";
import {PositionNFTMetadataFacet} from "../src/views/PositionNFTMetadataFacet.sol";
import {MultiPoolPositionViewFacet} from "../src/views/MultiPoolPositionViewFacet.sol";
import {AuctionManagementViewFacet} from "../src/views/AuctionManagementViewFacet.sol";
import {PositionManagementFacet} from "../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../src/equallend/PenaltyFacet.sol";
import {ActiveCreditViewFacet} from "../src/views/ActiveCreditViewFacet.sol";
import {AmmAuctionFacet} from "../src/EqualX/AmmAuctionFacet.sol";
import {AmmAuctionViewFacet} from "../src/views/AmmAuctionViewFacet.sol";
import {CommunityAuctionFacet} from "../src/EqualX/CommunityAuctionFacet.sol";
import {CommunityAuctionViewFacet} from "../src/views/CommunityAuctionViewFacet.sol";
import {MamCurveCreationFacet} from "../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../src/EqualX/MamCurveExecutionFacet.sol";
import {OptionsFacet} from "../src/derivatives/OptionsFacet.sol";
import {DerivativeViewFacet} from "../src/views/DerivativeViewFacet.sol";
import {MamCurveViewFacet} from "../src/views/MamCurveViewFacet.sol";
import {PointsViewFacet} from "../src/views/PointsViewFacet.sol";
import {PositionAgentTBAFacet} from "../src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "../src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "../src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentConfigFacet} from "../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {ModuleRegistryFacet} from "../src/modules/ModuleRegistryFacet.sol";
import {ModuleGatewayFacet} from "../src/modules/ModuleGatewayFacet.sol";
import {ModuleViewFacet} from "../src/modules/ModuleViewFacet.sol";
import {OptionToken} from "../src/derivatives/OptionToken.sol";
import {PositionMSCAImpl} from "../src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {Types} from "../src/libraries/Types.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

interface IPoolManagementFacetInitConfig {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

contract DeployV1Script is Script {
    uint256 internal constant V1_FACET_COUNT = 42;
    uint256 internal constant CUT_BATCH_SIZE = 14;

    struct BaseDeployment {
        address diamond;
        address positionNFT;
    }

    struct V1Deployment {
        address diamond;
        address positionNFT;
        address optionToken;
        address erc6551Implementation;
    }

    function runBase() external returns (BaseDeployment memory deployment) {
        address owner_ = vm.envAddress("OWNER");
        address timelock_ = vm.envAddress("TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        deployment = _deployBase(owner_, timelock_);
        vm.stopBroadcast();
    }

    function runDeployV1() external returns (V1Deployment memory deployment) {
        address owner_ = vm.envAddress("OWNER");
        address timelock_ = vm.envAddress("TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);
        require(deployer == owner_ || deployer == timelock_, "DeployV1: PRIVATE_KEY must be OWNER or TIMELOCK");

        vm.startBroadcast(deployerPrivateKey);

        BaseDeployment memory base = _deployBase(owner_, timelock_);
        _installV1Facets(base.diamond);

        address optionToken = _bootstrapOptionToken(base.diamond, owner_);
        address erc6551Implementation = _bootstrapAgentConfig(base.diamond);

        vm.stopBroadcast();

        deployment = V1Deployment({
            diamond: base.diamond,
            positionNFT: base.positionNFT,
            optionToken: optionToken,
            erc6551Implementation: erc6551Implementation
        });

        console2.log("diamond", deployment.diamond);
        console2.log("positionNFT", deployment.positionNFT);
        console2.log("optionToken", deployment.optionToken);
        console2.log("erc6551Implementation", deployment.erc6551Implementation);
    }

    function _deployBase(address owner_, address timelock_) internal returns (BaseDeployment memory deployment) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cut), _selectors(cut));
        cuts[1] = _cut(address(loupe), _selectors(loupe));
        cuts[2] = _cut(address(own), _selectors(own));

        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner_}));
        PositionNFT nftContract = new PositionNFT();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, timelock_, address(nftContract))
        );

        deployment = BaseDeployment({diamond: address(diamond), positionNFT: address(nftContract)});
    }

    function _installV1Facets(address diamond) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](V1_FACET_COUNT);
        uint256 i;

        {
            AdminFacet facet = new AdminFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MaintenanceFacet facet = new MaintenanceFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            AdminGovernanceFacet facet = new AdminGovernanceFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PoolManagementFacet facet = new PoolManagementFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            EqualIndexAdminFacetV3 facet = new EqualIndexAdminFacetV3();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            EqualIndexActionsFacetV3 facet = new EqualIndexActionsFacetV3();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            EqualIndexLendingFacet facet = new EqualIndexLendingFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            EqualIndexPositionFacet facet = new EqualIndexPositionFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            EqualIndexViewFacetV3 facet = new EqualIndexViewFacetV3();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            LiquidityViewFacet facet = new LiquidityViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            LoanViewFacet facet = new LoanViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            ConfigViewFacet facet = new ConfigViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PoolUtilizationViewFacet facet = new PoolUtilizationViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            LoanPreviewFacet facet = new LoanPreviewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionViewFacet facet = new PositionViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionNFTMetadataFacet facet = new PositionNFTMetadataFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MultiPoolPositionViewFacet facet = new MultiPoolPositionViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            AuctionManagementViewFacet facet = new AuctionManagementViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionManagementFacet facet = new PositionManagementFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            LendingFacet facet = new LendingFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PenaltyFacet facet = new PenaltyFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            ActiveCreditViewFacet facet = new ActiveCreditViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            AmmAuctionFacet facet = new AmmAuctionFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            AmmAuctionViewFacet facet = new AmmAuctionViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MamCurveCreationFacet facet = new MamCurveCreationFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MamCurveManagementFacet facet = new MamCurveManagementFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MamCurveExecutionFacet facet = new MamCurveExecutionFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            OptionsFacet facet = new OptionsFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            DerivativeViewFacet facet = new DerivativeViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            MamCurveViewFacet facet = new MamCurveViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PointsAdminFacet facet = new PointsAdminFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PointsViewFacet facet = new PointsViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PointsRedemptionFacet facet = new PointsRedemptionFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            CommunityAuctionFacet facet = new CommunityAuctionFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            CommunityAuctionViewFacet facet = new CommunityAuctionViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionAgentTBAFacet facet = new PositionAgentTBAFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionAgentRegistryFacet facet = new PositionAgentRegistryFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionAgentViewFacet facet = new PositionAgentViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            PositionAgentConfigFacet facet = new PositionAgentConfigFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            ModuleRegistryFacet facet = new ModuleRegistryFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            ModuleGatewayFacet facet = new ModuleGatewayFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }
        {
            ModuleViewFacet facet = new ModuleViewFacet();
            cuts[i++] = _cut(address(facet), _selectors(facet));
        }

        require(i == V1_FACET_COUNT, "DeployV1: bad facet count");
        _applyCutsInBatches(diamond, cuts, CUT_BATCH_SIZE);
    }

    function _bootstrapOptionToken(address diamond, address owner_) internal returns (address optionToken) {
        if (_facetAddressOrZero(diamond, OptionsFacet.setOptionToken.selector) == address(0)) {
            return address(0);
        }
        OptionToken deployedOptionToken = new OptionToken("", owner_, diamond);
        optionToken = address(deployedOptionToken);
        OptionsFacet(diamond).setOptionToken(optionToken);
    }

    function _bootstrapAgentConfig(address diamond) internal returns (address erc6551Implementation) {
        if (_facetAddressOrZero(diamond, PositionAgentConfigFacet.setERC6551Registry.selector) == address(0)) {
            return address(0);
        }

        address entryPoint = vm.envAddress("ENTRYPOINT_ADDRESS");
        address erc6551Registry = vm.envAddress("ERC6551_REGISTRY");
        address identityRegistry = vm.envAddress("IDENTITY_REGISTRY");

        require(entryPoint != address(0), "DeployV1: ENTRYPOINT_ADDRESS missing");
        require(erc6551Registry != address(0), "DeployV1: ERC6551_REGISTRY missing");
        require(identityRegistry != address(0), "DeployV1: IDENTITY_REGISTRY missing");
        require(entryPoint.code.length > 0, "DeployV1: ENTRYPOINT_ADDRESS has no code");
        require(erc6551Registry.code.length > 0, "DeployV1: ERC6551_REGISTRY has no code");
        require(identityRegistry.code.length > 0, "DeployV1: IDENTITY_REGISTRY has no code");

        PositionMSCAImpl impl = new PositionMSCAImpl(entryPoint);
        erc6551Implementation = address(impl);

        PositionAgentConfigFacet(diamond).setERC6551Registry(erc6551Registry);
        PositionAgentConfigFacet(diamond).setERC6551Implementation(erc6551Implementation);
        PositionAgentConfigFacet(diamond).setIdentityRegistry(identityRegistry);
    }

    function _applyCutsInBatches(address diamond, IDiamondCut.FacetCut[] memory cuts, uint256 batchSize) internal {
        uint256 offset;
        uint256 total = cuts.length;

        while (offset < total) {
            uint256 batchLen = total - offset;
            if (batchLen > batchSize) {
                batchLen = batchSize;
            }

            IDiamondCut.FacetCut[] memory batch = new IDiamondCut.FacetCut[](batchLen);
            for (uint256 i; i < batchLen; ++i) {
                batch[i] = cuts[offset + i];
            }

            IDiamondCut(diamond).diamondCut(batch, address(0), "");
            offset += batchLen;
        }
    }

    function _facetAddressOrZero(address diamond, bytes4 selector) internal view returns (address facet) {
        try IDiamondLoupe(diamond).facetAddress(selector) returns (address found) {
            facet = found;
        } catch {
            facet = address(0);
        }
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
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

    function _selectors(PointsAdminFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = PointsAdminFacet.setPointsPerAction.selector;
        s[1] = PointsAdminFacet.setPointsPerActionBatch.selector;
        s[2] = PointsAdminFacet.setDailyPointsCap.selector;
        s[3] = PointsAdminFacet.setAccrualCooldown.selector;
        s[4] = PointsAdminFacet.setRedemptionToken.selector;
        s[5] = PointsAdminFacet.setRedemptionEnabled.selector;
        s[6] = PointsAdminFacet.setRedemptionRate.selector;
        s[7] = PointsAdminFacet.setRedemptionGlobalMintCap.selector;
        s[8] = PointsAdminFacet.setRedemptionEpochConfig.selector;
    }

    function _selectors(PointsRedemptionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PointsRedemptionFacet.redeem.selector;
        s[1] = PointsRedemptionFacet.redeemFromPosition.selector;
    }

    function _selectors(MaintenanceFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = MaintenanceFacet.pokeMaintenance.selector;
        s[1] = MaintenanceFacet.settleMaintenance.selector;
    }

    function _selectors(AdminGovernanceFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](23);
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
        s[21] = AdminGovernanceFacet.setPositionNFT.selector;
        s[22] = AdminGovernanceFacet.setManagedPoolSystemShareBps.selector;
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

    function _selectors(EqualIndexLendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](16);
        s[0] = EqualIndexLendingFacet.configureLending.selector;
        s[1] = EqualIndexLendingFacet.configureBorrowFeeTiers.selector;
        s[2] = EqualIndexLendingFacet.borrowFromPosition.selector;
        s[3] = EqualIndexLendingFacet.repayFromPosition.selector;
        s[4] = EqualIndexLendingFacet.extendFromPosition.selector;
        s[5] = EqualIndexLendingFacet.recoverExpired.selector;
        s[6] = EqualIndexLendingFacet.getLoan.selector;
        s[7] = EqualIndexLendingFacet.getOutstandingPrincipal.selector;
        s[8] = EqualIndexLendingFacet.getLockedCollateralUnits.selector;
        s[9] = EqualIndexLendingFacet.getLendingConfig.selector;
        s[10] = EqualIndexLendingFacet.economicBalance.selector;
        s[11] = EqualIndexLendingFacet.maxBorrowable.selector;
        s[12] = EqualIndexLendingFacet.quoteBorrowBasket.selector;
        s[13] = EqualIndexLendingFacet.quoteBorrowFee.selector;
        s[14] = EqualIndexLendingFacet.getBorrowFeeTiers.selector;
        s[15] = EqualIndexLendingFacet.lendingModuleId.selector;
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

    function _selectors(PointsViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
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
        s[2] = PositionManagementFacet.depositToPosition.selector;
        s[3] = PositionManagementFacet.withdrawFromPosition.selector;
        s[4] = PositionManagementFacet.rollYieldToPosition.selector;
        s[5] = PositionManagementFacet.closePoolPosition.selector;
        s[6] = PositionManagementFacet.cleanupMembership.selector;
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = LendingFacet.openRollingFromPosition.selector;
        s[1] = LendingFacet.makePaymentFromPosition.selector;
        s[2] = LendingFacet.expandRollingFromPosition.selector;
        s[3] = LendingFacet.closeRollingCreditFromPosition.selector;
        s[4] = LendingFacet.openFixedFromPosition.selector;
        s[5] = LendingFacet.repayFixedFromPosition.selector;
    }

    function _selectors(PenaltyFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("penalizePositionRolling(uint256,uint256,address)"));
        s[1] = bytes4(keccak256("penalizePositionRolling(uint256,address)"));
        s[2] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,uint256,address)"));
        s[3] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,address)"));
    }

    function _selectors(ActiveCreditViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(AmmAuctionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[3] = AmmAuctionFacet.cancelAuction.selector;
        s[4] = AmmAuctionFacet.addLiquidity.selector;
    }

    function _selectors(AmmAuctionViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AmmAuctionViewFacet.getAuction.selector;
        s[1] = AmmAuctionViewFacet.previewSwap.selector;
    }

    function _selectors(CommunityAuctionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = CommunityAuctionFacet.createCommunityAuction.selector;
        s[1] = CommunityAuctionFacet.joinCommunityAuction.selector;
        s[2] = CommunityAuctionFacet.leaveCommunityAuction.selector;
        s[3] = CommunityAuctionFacet.claimFees.selector;
        s[4] = CommunityAuctionFacet.swapExactIn.selector;
        s[5] = CommunityAuctionFacet.finalizeAuction.selector;
        s[6] = CommunityAuctionFacet.cancelCommunityAuction.selector;
    }

    function _selectors(CommunityAuctionViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = CommunityAuctionViewFacet.getCommunityAuction.selector;
        s[1] = CommunityAuctionViewFacet.getMakerShare.selector;
        s[2] = CommunityAuctionViewFacet.previewJoin.selector;
        s[3] = CommunityAuctionViewFacet.previewLeave.selector;
        s[4] = CommunityAuctionViewFacet.getTotalMakers.selector;
        s[5] = CommunityAuctionViewFacet.previewCommunitySwap.selector;
    }

    function _selectors(MamCurveCreationFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = MamCurveCreationFacet.setMamPaused.selector;
        s[1] = MamCurveCreationFacet.setCurveProfile.selector;
        s[2] = MamCurveCreationFacet.getCurveProfile.selector;
        s[3] = MamCurveCreationFacet.isCurveProfileApproved.selector;
        s[4] = MamCurveCreationFacet.createCurve.selector;
        s[5] = MamCurveCreationFacet.createCurvesBatch.selector;
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
        s = new bytes4[](3);
        s[0] = MamCurveExecutionFacet.loadCurveForFill.selector;
        s[1] = bytes4(keccak256("executeCurveSwap(uint256,uint256,uint256,uint256,uint64,address)"));
        s[2] = bytes4(keccak256("executeCurveSwap(uint256,uint256,uint256,uint256,uint64,address,uint32,bytes32)"));
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

    function _selectors(ModuleRegistryFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ModuleRegistryFacet.registerModule.selector;
        s[1] = ModuleRegistryFacet.setModuleOwner.selector;
        s[2] = ModuleRegistryFacet.pauseModule.selector;
        s[3] = ModuleRegistryFacet.unpauseModule.selector;
        s[4] = ModuleRegistryFacet.setModuleCreationFee.selector;
        s[5] = ModuleRegistryFacet.setDefaultModuleAumBps.selector;
        s[6] = ModuleRegistryFacet.setModuleAumBps.selector;
        s[7] = ModuleRegistryFacet.setModuleAumBounds.selector;
        s[8] = ModuleRegistryFacet.setModuleDeactivationGraceEpochs.selector;
        s[9] = ModuleRegistryFacet.setModuleAciPaused.selector;
    }

    function _selectors(ModuleGatewayFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = ModuleGatewayFacet.encumberPosition.selector;
        s[1] = ModuleGatewayFacet.unencumberPosition.selector;
        s[2] = ModuleGatewayFacet.pokeModuleAum.selector;
    }

    function _selectors(ModuleViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = ModuleViewFacet.getModule.selector;
        s[1] = ModuleViewFacet.getModuleEncumbrance.selector;
        s[2] = ModuleViewFacet.getModuleEncumbranceForModule.selector;
        s[3] = ModuleViewFacet.getModuleAumState.selector;
        s[4] = ModuleViewFacet.getModuleAumConfig.selector;
        s[5] = ModuleViewFacet.isModuleAciPaused.selector;
    }
}

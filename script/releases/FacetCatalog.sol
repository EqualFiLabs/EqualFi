// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {AdminFacet} from "../../src/admin/AdminFacet.sol";
import {PointsAdminFacet} from "../../src/admin/PointsAdminFacet.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {FlashLoanFacet} from "../../src/equallend/FlashLoanFacet.sol";
import {FeeFacet} from "../../src/core/FeeFacet.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexLendingFacet} from "../../src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {LiquidityViewFacet} from "../../src/views/LiquidityViewFacet.sol";
import {LoanViewFacet} from "../../src/views/LoanViewFacet.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {EnhancedLoanViewFacet} from "../../src/views/EnhancedLoanViewFacet.sol";
import {PoolUtilizationViewFacet} from "../../src/views/PoolUtilizationViewFacet.sol";
import {LoanPreviewFacet} from "../../src/views/LoanPreviewFacet.sol";
import {PositionViewFacet} from "../../src/views/PositionViewFacet.sol";
import {PositionNFTMetadataFacet} from "../../src/views/PositionNFTMetadataFacet.sol";
import {MultiPoolPositionViewFacet} from "../../src/views/MultiPoolPositionViewFacet.sol";
import {AuctionManagementViewFacet} from "../../src/views/AuctionManagementViewFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {ActiveCreditViewFacet} from "../../src/views/ActiveCreditViewFacet.sol";
import {PointsViewFacet} from "../../src/views/PointsViewFacet.sol";
import {PointsRedemptionFacet} from "../../src/points/PointsRedemptionFacet.sol";
import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectAgreementFacet} from "../../src/equallend-direct/EqualLendDirectAgreementFacet.sol";
import {EqualLendDirectAgreementRatioFacet} from "../../src/equallend-direct/EqualLendDirectAgreementRatioFacet.sol";
import {EqualLendDirectLifecycleFacet} from "../../src/equallend-direct/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectViewFacet} from "../../src/views/EqualLendDirectViewFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "../../src/equallend-direct/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "../../src/equallend-direct/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "../../src/equallend-direct/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "../../src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol";
import {EqualLendDirectRollingViewFacet} from "../../src/views/EqualLendDirectRollingViewFacet.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {AmmAuctionViewFacet} from "../../src/views/AmmAuctionViewFacet.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {CommunityAuctionViewFacet} from "../../src/views/CommunityAuctionViewFacet.sol";
import {AtomicDeskFacet} from "../../src/EqualX/AtomicDeskFacet.sol";
import {SettlementEscrowFacet} from "../../src/EqualX/SettlementEscrowFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../../src/derivatives/FuturesFacet.sol";
import {DerivativeViewFacet} from "../../src/views/DerivativeViewFacet.sol";
import {MamCurveViewFacet} from "../../src/views/MamCurveViewFacet.sol";
import {PositionAgentTBAFacet} from "../../src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "../../src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "../../src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {ModuleViewFacet} from "../../src/modules/ModuleViewFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import {ILMIsolatedLiquidationFacet} from "../../src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import {ILMPooledAdminFacet} from "../../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";
import {ILMPooledFacet} from "../../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../../src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol";
import {ILMPooledViewFacet} from "../../src/ilm-pooled/facets/ILMPooledViewFacet.sol";
import {PerpsAdminFacet} from "../../src/perps/PerpsAdminFacet.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {PerpsLiquidationFacet} from "../../src/perps/PerpsLiquidationFacet.sol";
import {PerpsViewFacet} from "../../src/perps/PerpsViewFacet.sol";
import {DeployDiamondScript} from "../DeployDiamond.s.sol";
import {ApplyReport, FacetId, FacetPlan, IReleaseManifest, ManifestPlan} from "./ManifestTypes.sol";

abstract contract FacetCatalog is DeployDiamondScript {
    function _planManifest(address diamond, IReleaseManifest manifest) internal returns (ManifestPlan memory plan) {
        FacetId[] memory ids = manifest.facetIds();
        plan.manifestName = manifest.name();
        plan.facets = new FacetPlan[](ids.length);

        for (uint256 i; i < ids.length; ++i) {
            (address plannedFacet, bytes4[] memory selectors) = _deployFacet(ids[i]);
            bytes32 runtimeCodeHash = plannedFacet.codehash;
            address reusableFacet = _reusableFacetAddress(diamond, selectors, runtimeCodeHash);

            plan.facets[i].facetId = ids[i];
            plan.facets[i].runtimeCodeHash = runtimeCodeHash;
            plan.facets[i].selectors = selectors;

            if (reusableFacet != address(0)) {
                plan.facets[i].facetAddress = reusableFacet;
                plan.report.reusedFacetCount++;

                for (uint256 j; j < selectors.length; ++j) {
                    address currentFacet = _facetAddressOrZero(diamond, selectors[j]);
                    if (currentFacet == address(0)) {
                        plan.facets[i].addSelectorCount++;
                        plan.report.addedSelectorCount++;
                    } else {
                        plan.facets[i].unchangedSelectorCount++;
                        plan.report.unchangedSelectorCount++;
                    }
                }
            } else {
                plan.facets[i].deployImplementation = true;
                plan.report.deployedFacetCount++;

                for (uint256 j; j < selectors.length; ++j) {
                    address currentFacet = _facetAddressOrZero(diamond, selectors[j]);
                    if (currentFacet == address(0)) {
                        plan.facets[i].addSelectorCount++;
                        plan.report.addedSelectorCount++;
                    } else {
                        plan.facets[i].replaceSelectorCount++;
                        plan.report.replacedSelectorCount++;
                    }
                }
            }

            if (plan.facets[i].addSelectorCount > 0) {
                plan.report.addCutCount++;
            }
            if (plan.facets[i].replaceSelectorCount > 0) {
                plan.report.replaceCutCount++;
            }
        }
    }

    function _applyManifest(address diamond, IReleaseManifest manifest) internal returns (ApplyReport memory report) {
        report = _executeManifestPlan(diamond, _planManifest(diamond, manifest));
    }

    function _executeManifestPlan(address diamond, ManifestPlan memory plan)
        internal
        returns (ApplyReport memory report)
    {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](plan.facets.length * 2);
        uint256 cutCount;

        for (uint256 i; i < plan.facets.length; ++i) {
            FacetPlan memory facetPlan = plan.facets[i];
            address facetAddress = facetPlan.facetAddress;

            if (facetPlan.deployImplementation) {
                (facetAddress,) = _deployFacet(facetPlan.facetId);
            }

            if (facetPlan.addSelectorCount > 0) {
                cuts[cutCount++] = IDiamondCut.FacetCut({
                    facetAddress: facetAddress,
                    action: IDiamondCut.FacetCutAction.Add,
                    functionSelectors: _selectorsForAction(facetPlan.selectors, diamond, true)
                });
            }

            if (facetPlan.replaceSelectorCount > 0) {
                cuts[cutCount++] = IDiamondCut.FacetCut({
                    facetAddress: facetAddress,
                    action: IDiamondCut.FacetCutAction.Replace,
                    functionSelectors: _selectorsForAction(facetPlan.selectors, diamond, false)
                });
            }
        }

        IDiamondCut.FacetCut[] memory finalCuts = new IDiamondCut.FacetCut[](cutCount);
        for (uint256 i; i < cutCount; ++i) {
            finalCuts[i] = cuts[i];
        }

        if (finalCuts.length > 0) {
            IDiamondCut(diamond).diamondCut(finalCuts, address(0), "");
        }

        report = plan.report;
    }

    function _deployFacet(FacetId facetId) internal returns (address facet, bytes4[] memory selectors) {
        if (facetId == FacetId.DiamondCut) {
            DiamondCutFacet deployed = new DiamondCutFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.DiamondLoupe) {
            DiamondLoupeFacet deployed = new DiamondLoupeFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Ownership) {
            OwnershipFacet deployed = new OwnershipFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Admin) {
            AdminFacet deployed = new AdminFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.FlashLoan) {
            FlashLoanFacet deployed = new FlashLoanFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Fee) {
            FeeFacet deployed = new FeeFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.LiquidityView) {
            LiquidityViewFacet deployed = new LiquidityViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.LoanView) {
            LoanViewFacet deployed = new LoanViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Maintenance) {
            MaintenanceFacet deployed = new MaintenanceFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.AdminGovernance) {
            AdminGovernanceFacet deployed = new AdminGovernanceFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PoolManagement) {
            PoolManagementFacet deployed = new PoolManagementFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualIndexAdmin) {
            EqualIndexAdminFacetV3 deployed = new EqualIndexAdminFacetV3();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualIndexActions) {
            EqualIndexActionsFacetV3 deployed = new EqualIndexActionsFacetV3();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualIndexLending) {
            EqualIndexLendingFacet deployed = new EqualIndexLendingFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualIndexPosition) {
            EqualIndexPositionFacet deployed = new EqualIndexPositionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualIndexView) {
            EqualIndexViewFacetV3 deployed = new EqualIndexViewFacetV3();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ConfigView) {
            ConfigViewFacet deployed = new ConfigViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EnhancedLoanView) {
            EnhancedLoanViewFacet deployed = new EnhancedLoanViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PoolUtilizationView) {
            PoolUtilizationViewFacet deployed = new PoolUtilizationViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.LoanPreview) {
            LoanPreviewFacet deployed = new LoanPreviewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionView) {
            PositionViewFacet deployed = new PositionViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionNFTMetadata) {
            PositionNFTMetadataFacet deployed = new PositionNFTMetadataFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.MultiPoolPositionView) {
            MultiPoolPositionViewFacet deployed = new MultiPoolPositionViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.AuctionManagementView) {
            AuctionManagementViewFacet deployed = new AuctionManagementViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionManagement) {
            PositionManagementFacet deployed = new PositionManagementFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Lending) {
            LendingFacet deployed = new LendingFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Penalty) {
            PenaltyFacet deployed = new PenaltyFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ActiveCreditView) {
            ActiveCreditViewFacet deployed = new ActiveCreditViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PointsAdmin) {
            PointsAdminFacet deployed = new PointsAdminFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PointsView) {
            PointsViewFacet deployed = new PointsViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PointsRedemption) {
            PointsRedemptionFacet deployed = new PointsRedemptionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectOffer) {
            EqualLendDirectOfferFacet deployed = new EqualLendDirectOfferFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectAgreement) {
            EqualLendDirectAgreementFacet deployed = new EqualLendDirectAgreementFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectAgreementRatio) {
            EqualLendDirectAgreementRatioFacet deployed = new EqualLendDirectAgreementRatioFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectLifecycle) {
            EqualLendDirectLifecycleFacet deployed = new EqualLendDirectLifecycleFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectView) {
            EqualLendDirectViewFacet deployed = new EqualLendDirectViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectRollingOffer) {
            EqualLendDirectRollingOfferFacet deployed = new EqualLendDirectRollingOfferFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectRollingAgreement) {
            EqualLendDirectRollingAgreementFacet deployed = new EqualLendDirectRollingAgreementFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectRollingLifecycle) {
            EqualLendDirectRollingLifecycleFacet deployed = new EqualLendDirectRollingLifecycleFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectRollingPayment) {
            EqualLendDirectRollingPaymentFacet deployed = new EqualLendDirectRollingPaymentFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.EqualLendDirectRollingView) {
            EqualLendDirectRollingViewFacet deployed = new EqualLendDirectRollingViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.AmmAuction) {
            AmmAuctionFacet deployed = new AmmAuctionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.AmmAuctionView) {
            AmmAuctionViewFacet deployed = new AmmAuctionViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.CommunityAuction) {
            CommunityAuctionFacet deployed = new CommunityAuctionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.CommunityAuctionView) {
            CommunityAuctionViewFacet deployed = new CommunityAuctionViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.AtomicDesk) {
            AtomicDeskFacet deployed = new AtomicDeskFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.SettlementEscrow) {
            SettlementEscrowFacet deployed = new SettlementEscrowFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.MamCurveCreation) {
            MamCurveCreationFacet deployed = new MamCurveCreationFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.MamCurveManagement) {
            MamCurveManagementFacet deployed = new MamCurveManagementFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.MamCurveExecution) {
            MamCurveExecutionFacet deployed = new MamCurveExecutionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Options) {
            OptionsFacet deployed = new OptionsFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.Futures) {
            FuturesFacet deployed = new FuturesFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.DerivativeView) {
            DerivativeViewFacet deployed = new DerivativeViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.MamCurveView) {
            MamCurveViewFacet deployed = new MamCurveViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionAgentTBA) {
            PositionAgentTBAFacet deployed = new PositionAgentTBAFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionAgentRegistry) {
            PositionAgentRegistryFacet deployed = new PositionAgentRegistryFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionAgentView) {
            PositionAgentViewFacet deployed = new PositionAgentViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PositionAgentConfig) {
            PositionAgentConfigFacet deployed = new PositionAgentConfigFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ModuleRegistry) {
            ModuleRegistryFacet deployed = new ModuleRegistryFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ModuleGateway) {
            ModuleGatewayFacet deployed = new ModuleGatewayFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ModuleView) {
            ModuleViewFacet deployed = new ModuleViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMIsolatedAdmin) {
            ILMIsolatedAdminFacet deployed = new ILMIsolatedAdminFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMIsolated) {
            ILMIsolatedFacet deployed = new ILMIsolatedFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMIsolatedLiquidation) {
            ILMIsolatedLiquidationFacet deployed = new ILMIsolatedLiquidationFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMIsolatedView) {
            ILMIsolatedViewFacet deployed = new ILMIsolatedViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMPooledAdmin) {
            ILMPooledAdminFacet deployed = new ILMPooledAdminFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMPooled) {
            ILMPooledFacet deployed = new ILMPooledFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMPooledLiquidation) {
            ILMPooledLiquidationFacet deployed = new ILMPooledLiquidationFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.ILMPooledView) {
            ILMPooledViewFacet deployed = new ILMPooledViewFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PerpsAdmin) {
            PerpsAdminFacet deployed = new PerpsAdminFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PerpsExecution) {
            PerpsExecutionFacet deployed = new PerpsExecutionFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PerpsLiquidation) {
            PerpsLiquidationFacet deployed = new PerpsLiquidationFacet();
            return (address(deployed), _selectors(deployed));
        }
        if (facetId == FacetId.PerpsView) {
            PerpsViewFacet deployed = new PerpsViewFacet();
            return (address(deployed), _selectors(deployed));
        }

        revert("FacetCatalog: unsupported facet");
    }

    function _writeManifestArtifact(
        address diamond,
        address positionNFT,
        ManifestPlan memory plan,
        ApplyReport memory report
    ) internal {
        string memory root = vm.projectRoot();
        string memory deploymentsDir = string.concat(root, "/script/releases/deployments");
        string memory chainDir = string.concat(deploymentsDir, "/", vm.toString(block.chainid));

        vm.createDir(deploymentsDir, true);
        vm.createDir(chainDir, true);

        string memory artifact = "releaseArtifact";
        vm.serializeString(artifact, "manifest", plan.manifestName);
        vm.serializeUint(artifact, "chainId", block.chainid);
        vm.serializeAddress(artifact, "diamond", diamond);
        vm.serializeAddress(artifact, "positionNFT", positionNFT);
        vm.serializeUint(artifact, "deployedFacetCount", report.deployedFacetCount);
        vm.serializeUint(artifact, "reusedFacetCount", report.reusedFacetCount);
        vm.serializeUint(artifact, "addCutCount", report.addCutCount);
        vm.serializeUint(artifact, "replaceCutCount", report.replaceCutCount);
        vm.serializeUint(artifact, "addedSelectorCount", report.addedSelectorCount);
        vm.serializeUint(artifact, "replacedSelectorCount", report.replacedSelectorCount);
        vm.serializeUint(artifact, "unchangedSelectorCount", report.unchangedSelectorCount);

        for (uint256 i; i < plan.facets.length; ++i) {
            bytes4[] memory selectors = plan.facets[i].selectors;
            address facetAddress = selectors.length == 0 ? address(0) : _facetAddressOrZero(diamond, selectors[0]);
            string memory facetPrefix = string.concat("facet_", vm.toString(i), "_");

            vm.serializeUint(artifact, string.concat(facetPrefix, "id"), uint256(plan.facets[i].facetId));
            vm.serializeAddress(artifact, string.concat(facetPrefix, "address"), facetAddress);
            vm.serializeString(
                artifact,
                string.concat(facetPrefix, "codeHash"),
                vm.toString(facetAddress == address(0) ? bytes32(0) : facetAddress.codehash)
            );
            vm.serializeUint(artifact, string.concat(facetPrefix, "addSelectorCount"), plan.facets[i].addSelectorCount);
            vm.serializeUint(
                artifact,
                string.concat(facetPrefix, "replaceSelectorCount"),
                plan.facets[i].replaceSelectorCount
            );
            vm.serializeUint(
                artifact,
                string.concat(facetPrefix, "unchangedSelectorCount"),
                plan.facets[i].unchangedSelectorCount
            );
        }

        string memory json = vm.serializeUint(artifact, "facetCount", plan.facets.length);
        vm.writeJson(json, string.concat(chainDir, "/", plan.manifestName, ".json"));
    }

    function _facetAddressOrZero(address diamond, bytes4 selector) internal view returns (address facet) {
        if (diamond == address(0)) {
            return address(0);
        }
        facet = IDiamondLoupe(diamond).facetAddress(selector);
    }

    function _reusableFacetAddress(address diamond, bytes4[] memory selectors, bytes32 runtimeCodeHash)
        internal
        view
        returns (address reusableFacet)
    {
        if (diamond == address(0)) {
            return address(0);
        }

        for (uint256 i; i < selectors.length; ++i) {
            address currentFacet = IDiamondLoupe(diamond).facetAddress(selectors[i]);
            if (currentFacet == address(0)) {
                continue;
            }
            if (reusableFacet == address(0)) {
                reusableFacet = currentFacet;
                continue;
            }
            if (reusableFacet != currentFacet) {
                return address(0);
            }
        }

        if (reusableFacet == address(0) || reusableFacet.codehash != runtimeCodeHash) {
            return address(0);
        }
    }

    function _selectorsForAction(bytes4[] memory selectors, address diamond, bool wantMissing)
        internal
        view
        returns (bytes4[] memory filtered)
    {
        bytes4[] memory scratch = new bytes4[](selectors.length);
        uint256 count;

        for (uint256 i; i < selectors.length; ++i) {
            bool isMissing = _facetAddressOrZero(diamond, selectors[i]) == address(0);
            if (isMissing == wantMissing) {
                scratch[count++] = selectors[i];
            }
        }

        filtered = _trimSelectors(scratch, count);
    }

    function _trimSelectors(bytes4[] memory selectors, uint256 count) internal pure returns (bytes4[] memory trimmed) {
        trimmed = new bytes4[](count);
        for (uint256 i; i < count; ++i) {
            trimmed[i] = selectors[i];
        }
    }
}

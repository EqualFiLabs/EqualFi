// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FacetId} from "./ManifestTypes.sol";

abstract contract ReleaseStages {
    function _v1Base() internal pure returns (FacetId[] memory ids) {
        ids = new FacetId[](42);
        ids[0] = FacetId.Admin;
        ids[1] = FacetId.Maintenance;
        ids[2] = FacetId.AdminGovernance;
        ids[3] = FacetId.PoolManagement;
        ids[4] = FacetId.EqualIndexAdmin;
        ids[5] = FacetId.EqualIndexActions;
        ids[6] = FacetId.EqualIndexLending;
        ids[7] = FacetId.EqualIndexPosition;
        ids[8] = FacetId.EqualIndexView;
        ids[9] = FacetId.LiquidityView;
        ids[10] = FacetId.LoanView;
        ids[11] = FacetId.ConfigView;
        ids[12] = FacetId.PoolUtilizationView;
        ids[13] = FacetId.LoanPreview;
        ids[14] = FacetId.PositionView;
        ids[15] = FacetId.PositionNFTMetadata;
        ids[16] = FacetId.MultiPoolPositionView;
        ids[17] = FacetId.AuctionManagementView;
        ids[18] = FacetId.PositionManagement;
        ids[19] = FacetId.Lending;
        ids[20] = FacetId.Penalty;
        ids[21] = FacetId.ActiveCreditView;
        ids[22] = FacetId.AmmAuction;
        ids[23] = FacetId.AmmAuctionView;
        ids[24] = FacetId.MamCurveCreation;
        ids[25] = FacetId.MamCurveManagement;
        ids[26] = FacetId.MamCurveExecution;
        ids[27] = FacetId.Options;
        ids[28] = FacetId.DerivativeView;
        ids[29] = FacetId.MamCurveView;
        ids[30] = FacetId.PointsAdmin;
        ids[31] = FacetId.PointsView;
        ids[32] = FacetId.PointsRedemption;
        ids[33] = FacetId.CommunityAuction;
        ids[34] = FacetId.CommunityAuctionView;
        ids[35] = FacetId.PositionAgentTBA;
        ids[36] = FacetId.PositionAgentRegistry;
        ids[37] = FacetId.PositionAgentView;
        ids[38] = FacetId.PositionAgentConfig;
        ids[39] = FacetId.ModuleRegistry;
        ids[40] = FacetId.ModuleGateway;
        ids[41] = FacetId.ModuleView;
    }

    function _v2Direct() internal pure returns (FacetId[] memory ids) {
        ids = new FacetId[](10);
        ids[0] = FacetId.EqualLendDirectOffer;
        ids[1] = FacetId.EqualLendDirectAgreement;
        ids[2] = FacetId.EqualLendDirectAgreementRatio;
        ids[3] = FacetId.EqualLendDirectLifecycle;
        ids[4] = FacetId.EqualLendDirectView;
        ids[5] = FacetId.EqualLendDirectRollingOffer;
        ids[6] = FacetId.EqualLendDirectRollingAgreement;
        ids[7] = FacetId.EqualLendDirectRollingLifecycle;
        ids[8] = FacetId.EqualLendDirectRollingPayment;
        ids[9] = FacetId.EqualLendDirectRollingView;
    }

    function _v3IlmIsolated() internal pure returns (FacetId[] memory ids) {
        ids = new FacetId[](4);
        ids[0] = FacetId.ILMIsolatedAdmin;
        ids[1] = FacetId.ILMIsolated;
        ids[2] = FacetId.ILMIsolatedLiquidation;
        ids[3] = FacetId.ILMIsolatedView;
    }

    function _v4IlmPooled() internal pure returns (FacetId[] memory ids) {
        ids = new FacetId[](4);
        ids[0] = FacetId.ILMPooledAdmin;
        ids[1] = FacetId.ILMPooled;
        ids[2] = FacetId.ILMPooledLiquidation;
        ids[3] = FacetId.ILMPooledView;
    }

    function _v5Perps() internal pure returns (FacetId[] memory ids) {
        ids = new FacetId[](4);
        ids[0] = FacetId.PerpsAdmin;
        ids[1] = FacetId.PerpsExecution;
        ids[2] = FacetId.PerpsLiquidation;
        ids[3] = FacetId.PerpsView;
    }

    function _concat(FacetId[] memory a, FacetId[] memory b) internal pure returns (FacetId[] memory out) {
        out = new FacetId[](a.length + b.length);

        uint256 i;
        for (; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 j; j < b.length; ++j) {
            out[i + j] = b[j];
        }
    }
}

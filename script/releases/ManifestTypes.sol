// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum FacetId {
    DiamondCut,
    DiamondLoupe,
    Ownership,
    Admin,
    FlashLoan,
    Fee,
    LiquidityView,
    LoanView,
    Maintenance,
    AdminGovernance,
    PoolManagement,
    EqualIndexAdmin,
    EqualIndexActions,
    EqualIndexLending,
    EqualIndexPosition,
    EqualIndexView,
    ConfigView,
    EnhancedLoanView,
    PoolUtilizationView,
    LoanPreview,
    PositionView,
    PositionNFTMetadata,
    MultiPoolPositionView,
    AuctionManagementView,
    PositionManagement,
    Lending,
    Penalty,
    ActiveCreditView,
    PointsAdmin,
    PointsView,
    PointsRedemption,
    EqualLendDirectOffer,
    EqualLendDirectAgreement,
    EqualLendDirectAgreementRatio,
    EqualLendDirectLifecycle,
    EqualLendDirectView,
    EqualLendDirectRollingOffer,
    EqualLendDirectRollingAgreement,
    EqualLendDirectRollingLifecycle,
    EqualLendDirectRollingPayment,
    EqualLendDirectRollingView,
    AmmAuction,
    AmmAuctionView,
    CommunityAuction,
    CommunityAuctionView,
    AtomicDesk,
    SettlementEscrow,
    MamCurveCreation,
    MamCurveManagement,
    MamCurveExecution,
    Options,
    Futures,
    DerivativeView,
    MamCurveView,
    PositionAgentTBA,
    PositionAgentRegistry,
    PositionAgentView,
    PositionAgentConfig,
    ModuleRegistry,
    ModuleGateway,
    ModuleView,
    ILMIsolatedAdmin,
    ILMIsolated,
    ILMIsolatedLiquidation,
    ILMIsolatedView,
    ILMPooledAdmin,
    ILMPooled,
    ILMPooledLiquidation,
    ILMPooledView,
    PerpsAdmin,
    PerpsExecution,
    PerpsLiquidation,
    PerpsView
}

struct ApplyReport {
    uint256 deployedFacetCount;
    uint256 reusedFacetCount;
    uint256 addCutCount;
    uint256 replaceCutCount;
    uint256 addedSelectorCount;
    uint256 replacedSelectorCount;
    uint256 unchangedSelectorCount;
}

struct FacetPlan {
    FacetId facetId;
    address facetAddress;
    bytes32 runtimeCodeHash;
    bool deployImplementation;
    uint256 addSelectorCount;
    uint256 replaceSelectorCount;
    uint256 unchangedSelectorCount;
    bytes4[] selectors;
}

struct ManifestPlan {
    string manifestName;
    ApplyReport report;
    FacetPlan[] facets;
}

interface IReleaseManifest {
    function name() external pure returns (string memory);
    function facetIds() external pure returns (FacetId[] memory);
}

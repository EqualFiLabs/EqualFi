# EqualLend / EqualIndex Gas Estimates

_Generated via `forge test --match-path test/root/GasScenarioReport.t.sol --gas-report` and `forge test --match-path "test/gas/*t.sol" --gas-report` on 2026-01-07 (UTC)._
_Sources of truth: `gas-report-scenarios.txt` (scenario tables), `gas-report-latest.txt` (function-level tables), and `gas-report-direct-limit-order.txt` (limit order gas scenarios)._

## Methodology
- Scenario report values come from the dedicated gas scenario suite and reflect end-to-end flows.
- Function-level values use the **Max** column to avoid 0-min artifacts when a function is invoked during setup.
- Gas tests pause metering during setup so the reported values focus on the target call.
- Derivative swap harness values are from single-file gas runs and are appended to `gas-report-latest.txt`.
- Options/Futures harness values are from single-file gas runs and are appended to `gas-report-latest.txt`.

## Scenario Benchmarks (GasScenarioReport.t.sol)
### EqualIndex Flows
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Index creation w/ fee (`test_gas_IndexCreateWithFee`) | `EqualIndexFacetV3.createIndex` | **2,648,643** |
| Index mint only (`test_gas_IndexMintOnly`) | `EqualIndexFacetV3.mint` | **260,240** |
| Index burn only (`test_gas_IndexBurnOnly`) | `EqualIndexFacetV3.burn` | **104,583** |
| Index flash loan fee split (`test_gas_IndexFlashLoanFeeSplit`) | `EqualIndexFacetV3.flashLoan` | **88,506** |
| Index mint + burn (`test_gas_IndexMintBurnFlow`) | `EqualIndexFacetV3.mint + EqualIndexFacetV3.burn` | **9,163,581** |

_Notes_:
- Full per-function min/avg/median/max data for `EqualIndexFacetV3` and `IndexToken` are in `gas-report-scenarios.txt`.

### Pool Creation & Admin
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Minimal pool initialization (`test_gas_PoolInitMinimal`) | `PoolManagementFacet.initPool` | **790,494** |

_Notes_:
- Pool creation lives in `PoolManagementFacet`; non-governance callers also pay the configured creation fee (not included here).

### Position Management & Membership
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Mint + deposit (`test_gas_PositionMintAndDeposit`) | `PositionManagementFacet.mintPosition + depositToPosition` | **474,480** |
| Deposit only (`test_gas_PositionDepositOnly`) | `PositionManagementFacet.depositToPosition` | **249,047** |
| Withdraw only (`test_gas_PositionWithdrawOnly`) | `PositionManagementFacet.withdrawFromPosition` | **72,447** |
| Roll yield to principal (`test_gas_RollYieldToPosition`) | `PositionManagementFacet.rollYieldToPosition` | **62,464** |
| Close pool position (no commitments) (`test_gas_PositionClosePoolPosition`) | `PositionManagementFacet.closePoolPosition` | **78,027** |
| Deposit + withdraw + cleanup (`test_gas_PositionDepositWithdrawCloseCleanup`) | `PositionManagementFacet.depositToPosition + withdrawFromPosition + cleanupMembership` | **6,341,255** |

### Borrowing
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Open rolling borrow (`test_gas_BorrowRollingOnly`) | `LendingFacet.openRollingFromPosition` | **299,313** |
| Open fixed-term borrow (`test_gas_BorrowFixedOnly`) | `LendingFacet.openFixedFromPosition` | **523,157** |

### Loan Lifecycles
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling lifecycle (`test_gas_RollingLifecycle`) | `LendingFacet.openRollingFromPosition + makePaymentFromPosition + closeRollingCreditFromPosition` | **7,482,624** |
| Fixed lifecycle (`test_gas_FixedLifecycle`) | `LendingFacet.openFixedFromPosition + repayFixedFromPosition` | **7,691,498** |

### Direct Offers
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Post lender offer (`test_gas_DirectPostOfferOnly`) | `EqualLendDirectOfferFacet.postOffer` | **507,117** |
| Accept lender offer (`test_gas_DirectAcceptOfferOnly`) | `EqualLendDirectAgreementFacet.acceptOffer` | **1,024,393** |
| Post borrower offer (`test_gas_DirectPostBorrowerOfferOnly`) | `EqualLendDirectOfferFacet.postBorrowerOffer` | **481,546** |
| Accept borrower offer (`test_gas_DirectAcceptBorrowerOfferOnly`) | `EqualLendDirectAgreementFacet.acceptBorrowerOffer` | **1,027,999** |
| Direct offer repay flow (`test_gas_DirectOfferRepayFlow`) | `EqualLendDirectOfferFacet.postOffer + EqualLendDirectAgreementFacet.acceptOffer + EqualLendDirectLifecycleFacet.repay` | **40,263,463** |

### Penalties
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling penalty (`test_gas_PenaltyRolling`) | `PenaltyFacet.penalizePositionRolling` | **5,732,127** |
| Fixed penalty (`test_gas_PenaltyFixed`) | `PenaltyFacet.penalizePositionFixed` | **5,855,478** |

### Derivative swap harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas (max) |
| --- | --- | --- |
| AMM swap exact-in (`testGasSwapExactIn`) | `AmmAuctionFacet.swapExactIn` | **189,321** |
| MAM curve swap (`testGasExecuteCurveSwap`) | `MamCurveFacet.executeCurveSwap` | **198,485** |

### Options & Futures harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas (max) |
| --- | --- | --- |
| Options create series (`testGasCreateOptionSeries`) | `OptionsFacet.createOptionSeries` | **665,690** |
| Options exercise (`testGasExerciseOptions`) | `OptionsFacet.exerciseOptions` | **180,024** |
| Futures create series (`testGasCreateFuturesSeries`) | `FuturesFacet.createFuturesSeries` | **667,815** |
| Futures settle (`testGasSettleFutures`) | `FuturesFacet.settleFutures` | **177,416** |

## Function-Level Gas Tests (test/gas/*t.sol)
### EqualIndexAdminFacetV3
| Function | Gas (max) |
| --- | --- |
| `setIndexFees` | 61,147 |

### IndexToken (state-changing)
| Function | Gas (max) |
| --- | --- |
| `mintIndexUnits` | 71,095 |
| `burnIndexUnits` | 31,932 |
| `recordMintDetails` | 59,912 |
| `recordBurnDetails` | 60,528 |
| `setFlashFeeBps` | 26,668 |

### IndexToken (views)
| Function | Gas (max) |
| --- | --- |
| `assetsPaginated` | 13,042 |
| `bundleAmountsPaginated` | 13,005 |
| `previewMintPaginated` | 58,182 |
| `previewRedeem` | 65,627 |
| `previewRedeemPaginated` | 73,354 |
| `previewFlashLoanPaginated` | 22,237 |
| `isSolvent` | 24,870 |

### EqualIndexViewFacetV3 (views)
| Function | Gas (max) |
| --- | --- |
| `getIndexAssets` | 22,647 |
| `getIndexAssetCount` | 4,647 |
| `getProtocolBalance` | 2,442 |

### Direct lifecycle
| Function | Gas (max) |
| --- | --- |
| `exerciseDirect` | 292,991 |
| `callDirect` | 41,979 |

### Direct offer cancellations
| Function | Gas (max) |
| --- | --- |
| `cancelOffer` | 82,429 |
| `cancelBorrowerOffer` | 95,638 |
| `cancelRatioTrancheOffer` | 64,629 |
| `cancelBorrowerRatioTrancheOffer` | 64,565 |
| `cancelOffersForPosition(uint256)` | 85,188 |
| `cancelOffersForPosition(bytes32)` | 80,136 |

### Rolling offers & lifecycle
| Function | Gas (max) |
| --- | --- |
| `postRollingOffer` | 515,271 |
| `postBorrowerRollingOffer` | 516,188 |
| `acceptRollingOffer` | 1,106,527 |
| `cancelRollingOffer` | 60,872 |
| `makeRollingPayment` | 155,584 |
| `exerciseRolling` | 213,294 |
| `repayRollingInFull` | 235,859 |
| `recoverRolling` | 216,176 |

### Rolling views
| Function | Gas (max) |
| --- | --- |
| `getRollingAgreement` | 36,223 |
| `getRollingOffer` | 27,375 |
| `getRollingBorrowerOffer` | 27,356 |
| `calculateRollingPayment` | 7,129 |
| `getRollingStatus` | 4,874 |
| `aggregateRollingExposure` | 16,509 |

### Limit order views
| Function | Gas (max) |
| --- | --- |
| `getLimitOrder` | 26,804 |
| `getActiveLimitOrders` | 6,300 |
| `getLimitOrderEncumbrance` | 14,278 |
| `getLimitOrdersByPosition` | 7,828 |
| `getLimitOrderConfig` | 2,850 |

### Diamond loupe views
| Function | Gas (max) |
| --- | --- |
| `facetAddress` | 2,490 |
| `facetAddresses` | 654,685 |
| `facetFunctionSelectors` | 461,216 |
| `supportsInterface` | 2,365 |

### EqualLendDirectViewFacet (views)
| Function | Gas (max) |
| --- | --- |
| `fillsRemaining` | 11,815 |
| `getBorrowerAgreements` | 16,194 |
| `getBorrowerOffer` | 24,968 |
| `getBorrowerOffers` | 18,838 |
| `getBorrowerRatioTrancheOffer` | 29,703 |
| `getLenderOffers` | 18,596 |
| `getOffer` | 27,463 |
| `getOfferSummary` | 30,296 |
| `getOfferTranche` | 12,821 |
| `getPoolActiveDirectLent` | 2,585 |
| `getPositionDirectState` | 15,667 |
| `getRatioBorrowerOffers` | 16,079 |
| `getRatioLenderOffers` | 21,113 |
| `getRatioTrancheOffer` | 29,952 |
| `getRatioTrancheStatus` | 16,266 |
| `getTrancheStatus` | 12,802 |
| `isTrancheDepleted` | 12,151 |
| `isTrancheOffer` | 4,945 |

### Pool Management - Initialization
| Function | Gas (max) |
| --- | --- |
| `initPoolWithActionFees` | 286,456 |
| `initManagedPool` | 452,339 |

### Pool Management - Managed config
| Function | Gas (max) |
| --- | --- |
| `setRollingApy` | 33,604 |
| `setRollingApyExternal` | 33,621 |
| `setDepositorLTV` | 34,061 |
| `setExternalBorrowCR` | 33,611 |
| `setMinDepositAmount` | 33,623 |
| `setMinLoanAmount` | 33,381 |
| `setMinTopupAmount` | 33,645 |
| `setDepositCap` | 33,437 |
| `setIsCapped` | 33,179 |
| `setMaxUserCount` | 33,651 |
| `setMaintenanceRate` | 36,233 |
| `setFlashLoanFee` | 33,713 |
| `setActionFees` | 90,233 |

### Pool Management - Whitelist & manager
| Function | Gas (max) |
| --- | --- |
| `addToWhitelist` | 59,583 |
| `removeFromWhitelist` | 37,852 |
| `setWhitelistEnabled` | 34,987 |
| `transferManager` | 34,203 |
| `renounceManager` | 33,731 |

### PositionManagementFacet
| Function | Gas (max) |
| --- | --- |
| `mintPositionWithDeposit` | 437,409 |

### FlashLoanFacet (includes onFlashLoan callback)
| Function | Gas (max) |
| --- | --- |
| `flashLoan` | 111,004 |

### FeeFacet (views)
| Function | Gas (max) |
| --- | --- |
| `getPoolActionFee` | 4,989 |
| `getIndexActionFee` | 4,942 |
| `previewActionFee` | 4,747 |
| `previewIndexActionFee` | 4,873 |
| `getPoolActionFees` | 24,939 |
| `previewActionFees` | 24,642 |

### ActiveCreditViewFacet
| Function | Gas (max) |
| --- | --- |
| `getActiveCreditIndex` | 8,798 |
| `getActiveCreditStates` | 16,217 |
| `getActiveCreditStatesByPosition` | 24,200 |
| `getActiveCreditStatus` | 13,039 |
| `getActiveCreditStatusByPosition` | 21,188 |
| `pendingActiveCredit` | 11,569 |
| `pendingActiveCreditByPosition` | 19,727 |
| `selectors` | 1,584 |

### ConfigViewFacet
| Function | Gas (max) |
| --- | --- |
| `getAumFeeInfo` | 6,810 |
| `getFixedTermConfigs` | 5,137 |
| `getFlashConfig` | 4,799 |
| `getImmutableConfig` | 36,354 |
| `getMaintenanceState` | 11,469 |
| `getManagedPoolConfig` | 41,571 |
| `getMinDepositAmount` | 4,619 |
| `getMinLoanAmount` | 4,553 |
| `getPoolCaps` | 7,132 |
| `getPoolConfig` | 9,482 |
| `getPoolInfo` | 40,882 |
| `getPoolList` | 45,189 |
| `getPoolManager` | 4,753 |
| `getPoolUnderlying` | 2,829 |
| `getRollingDelinquencyThresholds` | 2,948 |
| `isManagedPool` | 4,785 |
| `isPoolDeprecated` | 4,967 |
| `isWhitelistEnabled` | 7,051 |
| `isWhitelisted` | 18,713 |
| `selectors` | 4,576 |

### EnhancedLoanViewFacet
| Function | Gas (max) |
| --- | --- |
| `canOpenFixedLoan` | 32,867 |
| `getFixedLoanAccrued` | 11,389 |
| `getUserFixedLoansDetailed` | 24,821 |
| `getUserFixedLoansPaginated` | 23,858 |
| `getUserHealthMetrics` | 32,893 |
| `previewBorrowFixed` | 32,616 |
| `previewRepayFixed` | 9,441 |
| `selectors` | 1,776 |

### EqualIndexViewFacetV3
| Function | Gas (max) |
| --- | --- |
| `getIndexAssets` | 22,647 |
| `getIndexAssetCount` | 4,647 |
| `getProtocolBalance` | 2,442 |

### EqualLendDirectViewFacet
| Function | Gas (max) |
| --- | --- |
| `fillsRemaining` | 11,815 |
| `getBorrowerAgreements` | 16,194 |
| `getBorrowerOffer` | 24,968 |
| `getBorrowerOffers` | 18,838 |
| `getBorrowerRatioTrancheOffer` | 29,703 |
| `getLenderOffers` | 18,596 |
| `getOffer` | 27,463 |
| `getOfferSummary` | 30,296 |
| `getOfferTranche` | 12,821 |
| `getPoolActiveDirectLent` | 2,585 |
| `getPositionDirectState` | 15,667 |
| `getRatioBorrowerOffers` | 16,079 |
| `getRatioLenderOffers` | 21,113 |
| `getRatioTrancheOffer` | 29,952 |
| `getRatioTrancheStatus` | 16,266 |
| `getTrancheStatus` | 12,802 |
| `isTrancheDepleted` | 12,151 |
| `isTrancheOffer` | 4,945 |

### LiquidityViewFacet
| Function | Gas (max) |
| --- | --- |
| `getTotalPoolDeposits` | 4,581 |
| `getUserBalances` | 11,234 |
| `pendingYield` | 15,574 |
| `totalAvailableLiquidity` | 7,956 |
| `selectors` | 1,049 |

### LoanViewFacet
| Function | Gas (max) |
| --- | --- |
| `getRollingLoan` | 12,034 |
| `previewBorrowExternal` | 4,733 |
| `previewBorrowRolling` | 7,016 |
| `selectors` | 1,405 |

### MultiPoolPositionViewFacet
| Function | Gas (max) |
| --- | --- |
| `getMultiPoolPositionState` | 94,786 |
| `getPositionActivePools` | 37,362 |
| `getPositionAggregatedSummary` | 88,915 |
| `getPositionDirectAgreementIds` | 22,279 |
| `getPositionDirectAgreements` | 87,116 |
| `getPositionDirectSummary` | 41,242 |
| `getPositionDirectSummaryByAsset` | 85,022 |
| `getPositionPoolData` | 36,690 |
| `getPositionPoolDataPoolOnly` | 34,239 |
| `getPositionPoolMemberships` | 36,682 |
| `getPositionPoolStates` | 67,203 |
| `getUserPositions` | 16,409 |
| `isPositionMemberOfPool` | 10,802 |
| `selectors` | 3,389 |

### PoolUtilizationViewFacet
| Function | Gas (max) |
| --- | --- |
| `getPoolCapacity` | 13,076 |
| `getPoolStats` | 14,777 |
| `selectors` | 1,238 |

### PositionViewFacet
| Function | Gas (max) |
| --- | --- |
| `getLoansDetails` | 19,281 |
| `getPositionLoanIds` | 17,798 |
| `getPositionLoanSummary` | 31,340 |
| `getPositionMetadata` | 14,373 |
| `getPositionSolvency` | 22,195 |
| `getPositionState` | 51,471 |
| `isPositionDelinquent` | 15,831 |
| `selectors` | 1,747 |

### LoanPreviewFacet
| Function | Gas (max) |
| --- | --- |
| `selectors` | 1,363 |

### MaintenanceFacet
| Function | Gas (max) |
| --- | --- |
| `selectors` | 715 |

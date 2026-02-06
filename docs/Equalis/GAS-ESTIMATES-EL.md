# EqualLend / EqualIndex Gas Estimates

_Generated via `forge test --match-path test/root/GasScenarioReport.t.sol --gas-report`, `forge test --match-path "test/gas/*t.sol" --gas-report`, and single-file derivative gas harness runs on 2026-02-06 (UTC)._
_Sources of truth: `gas-report-scenarios.txt` (scenario tables) and `gas-report-latest.txt` (function-level + derivative harness tables)._

## Methodology
- Scenario report values come from the dedicated gas scenario suite and reflect end-to-end flows.
- Function-level values use the **Max** column to avoid 0-min artifacts when a function is invoked during setup.
- Gas tests pause metering during setup so the reported values focus on the target call.
- Derivative AMM/MAM swap values use `swap_only` deltas captured inside the test (`gasleft()` before and after the swap call), then logged via `log_named_uint`.
- This isolates swap execution from setup noise and from `--gas-report` aggregation behavior.
- `swap_only` still includes test-context call overhead (`vm.prank`, external call frame), so treat it as a relative benchmark under the same harness, not exact EOA tx cost.
- Options/Futures harness values are from single-file gas runs and are appended to `gas-report-latest.txt`.
- `N/A` indicates no active gas benchmark for that function in the current test suites.

## Scenario Benchmarks (GasScenarioReport.t.sol)
### EqualIndex Flows
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Index creation w/ fee (`test_gas_IndexCreateWithFee`) | `EqualIndexFacetV3.createIndex` | **2,974,326** |
| Index mint only (`test_gas_IndexMintOnly`) | `EqualIndexFacetV3.mint` | **341,778** |
| Index burn only (`test_gas_IndexBurnOnly`) | `EqualIndexFacetV3.burn` | **148,208** |
| Index flash loan fee split (`test_gas_IndexFlashLoanFeeSplit`) | `EqualIndexFacetV3.flashLoan` | **133,879** |
| Index mint + burn (`test_gas_IndexMintBurnFlow`) | `EqualIndexFacetV3.mint + EqualIndexFacetV3.burn` | **11,735,828** |

_Notes_:
- Full per-function min/avg/median/max data for `EqualIndexFacetV3` and `IndexToken` are in `gas-report-scenarios.txt`.

### Pool Creation & Admin
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Minimal pool initialization (`test_gas_PoolInitMinimal`) | `PoolManagementFacet.initPool` | **811,680** |

_Notes_:
- Pool creation lives in `PoolManagementFacet`; non-governance callers also pay the configured creation fee (not included here).

### Position Management & Membership
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Mint + deposit (`test_gas_PositionMintAndDeposit`) | `PositionManagementFacet.mintPosition + depositToPosition` | **479,300** |
| Deposit only (`test_gas_PositionDepositOnly`) | `PositionManagementFacet.depositToPosition` | **249,309** |
| Withdraw only (`test_gas_PositionWithdrawOnly`) | `PositionManagementFacet.withdrawFromPosition` | **107,910** |
| Roll yield to principal (`test_gas_RollYieldToPosition`) | `PositionManagementFacet.rollYieldToPosition` | **102,292** |
| Close pool position (no commitments) (`test_gas_PositionClosePoolPosition`) | `PositionManagementFacet.closePoolPosition` | **105,813** |
| Deposit + withdraw + cleanup (`test_gas_PositionDepositWithdrawCloseCleanup`) | `PositionManagementFacet.depositToPosition + withdrawFromPosition + cleanupMembership` | **6,704,229** |

### Borrowing
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Open rolling borrow (`test_gas_BorrowRollingOnly`) | `LendingFacet.openRollingFromPosition` | **349,957** |
| Open fixed-term borrow (`test_gas_BorrowFixedOnly`) | `LendingFacet.openFixedFromPosition` | **585,977** |

### Loan Lifecycles
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling lifecycle (`test_gas_RollingLifecycle`) | `LendingFacet.openRollingFromPosition + makePaymentFromPosition + closeRollingCreditFromPosition` | **7,782,239** |
| Fixed lifecycle (`test_gas_FixedLifecycle`) | `LendingFacet.openFixedFromPosition + repayFixedFromPosition` | **7,991,123** |

### Direct Offers
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Post lender offer (`test_gas_DirectPostOfferOnly`) | `EqualLendDirectOfferFacet.postOffer` | **625,480** |
| Accept lender offer (`test_gas_DirectAcceptOfferOnly`) | `EqualLendDirectAgreementFacet.acceptOffer` | **1,072,298** |
| Post borrower offer (`test_gas_DirectPostBorrowerOfferOnly`) | `EqualLendDirectOfferFacet.postBorrowerOffer` | **600,165** |
| Accept borrower offer (`test_gas_DirectAcceptBorrowerOfferOnly`) | `EqualLendDirectAgreementFacet.acceptBorrowerOffer` | **1,082,391** |
| Direct offer repay flow (`test_gas_DirectOfferRepayFlow`) | `EqualLendDirectOfferFacet.postOffer + EqualLendDirectAgreementFacet.acceptOffer + EqualLendDirectLifecycleFacet.repay` | **41,895,777** |

### Penalties
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling penalty (`test_gas_PenaltyRolling`) | `PenaltyFacet.penalizePositionRolling` | **5,776,480** |
| Fixed penalty (`test_gas_PenaltyFixed`) | `PenaltyFacet.penalizePositionFixed` | **5,899,903** |

### Derivative swap harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas (`swap_only`) |
| --- | --- | --- |
| AMM swap exact-in (`testGasSwapExactIn`) | `AmmAuctionFacet.swapExactIn` | **197,872** |
| MAM curve swap (`testGasExecuteCurveSwap`) | `MamCurveFacet.executeCurveSwap` | **257,545** |

### Options & Futures harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas (max) |
| --- | --- | --- |
| Options create series (`testGasCreateOptionSeries`) | `OptionsFacet.createOptionSeries` | **797,957** |
| Options exercise (`testGasExerciseOptions`) | `OptionsFacet.exerciseOptions` | **218,631** |
| Futures create series (`testGasCreateFuturesSeries`) | `FuturesFacet.createFuturesSeries` | **798,409** |
| Futures settle (`testGasSettleFutures`) | `FuturesFacet.settleFutures` | **216,618** |

## Function-Level Gas Tests (test/gas/*t.sol)
### EqualIndexAdminFacetV3
| Function | Gas (max) |
| --- | --- |
| `setIndexFees` | 65,204 |

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
| `previewMintPaginated` | 58,006 |
| `previewRedeem` | 65,450 |
| `previewRedeemPaginated` | 73,178 |
| `previewFlashLoanPaginated` | 22,237 |
| `isSolvent` | 24,870 |

### EqualIndexViewFacetV3 (views)
| Function | Gas (max) |
| --- | --- |
| `getIndexAssets` | 22,647 |
| `getIndexAssetCount` | 4,625 |
| `getProtocolBalance` | 242 |

### Direct lifecycle
| Function | Gas (max) |
| --- | --- |
| `exerciseDirect` | 301,347 |
| `callDirect` | 42,003 |

### Direct offer cancellations
| Function | Gas (max) |
| --- | --- |
| `cancelOffer` | 135,648 |
| `cancelBorrowerOffer` | 148,663 |
| `cancelRatioTrancheOffer` | 117,660 |
| `cancelBorrowerRatioTrancheOffer` | 117,607 |
| `cancelOffersForPosition(uint256)` | 135,599 |
| `cancelOffersForPosition(bytes32)` | 130,596 |

### Rolling offers & lifecycle
| Function | Gas (max) |
| --- | --- |
| `postRollingOffer` | 633,829 |
| `postBorrowerRollingOffer` | 634,981 |
| `acceptRollingOffer` | 1,163,691 |
| `cancelRollingOffer` | 113,955 |
| `makeRollingPayment` | 184,877 |
| `exerciseRolling` | 253,615 |
| `repayRollingInFull` | 272,749 |
| `recoverRolling` | 333,038 |

### Rolling views
| Function | Gas (max) |
| --- | --- |
| `getRollingAgreement` | 36,217 |
| `getRollingOffer` | 27,375 |
| `getRollingBorrowerOffer` | 27,356 |
| `calculateRollingPayment` | 7,129 |
| `getRollingStatus` | 4,874 |
| `aggregateRollingExposure` | 16,509 |

### Limit order views
| Function | Gas (max) |
| --- | --- |
| `getLimitOrder` | N/A |
| `getActiveLimitOrders` | N/A |
| `getLimitOrderEncumbrance` | N/A |
| `getLimitOrdersByPosition` | N/A |
| `getLimitOrderConfig` | N/A |

### Diamond loupe views
| Function | Gas (max) |
| --- | --- |
| `facetAddress` | 2,490 |
| `facetAddresses` | 603,868 |
| `facetFunctionSelectors` | 432,320 |
| `supportsInterface` | 2,365 |

### EqualLendDirectViewFacet (views)
| Function | Gas (max) |
| --- | --- |
| `fillsRemaining` | 11,793 |
| `getBorrowerAgreements` | 16,123 |
| `getBorrowerOffer` | 24,881 |
| `getBorrowerOffers` | 18,745 |
| `getBorrowerRatioTrancheOffer` | 29,571 |
| `getLenderOffers` | 18,547 |
| `getOffer` | 27,331 |
| `getOfferSummary` | 30,230 |
| `getOfferTranche` | 12,821 |
| `getPoolActiveDirectLent` | 2,541 |
| `getPositionDirectState` | 17,756 |
| `getRatioBorrowerOffers` | 16,052 |
| `getRatioLenderOffers` | 21,042 |
| `getRatioTrancheOffer` | 29,842 |
| `getRatioTrancheStatus` | 16,222 |
| `getTrancheStatus` | 12,802 |
| `isTrancheDepleted` | 12,129 |
| `isTrancheOffer` | 4,901 |

### Pool Management - Initialization
| Function | Gas (max) |
| --- | --- |
| `initPoolWithActionFees` | 306,951 |
| `initManagedPool` | 720,101 |

### Pool Management - Managed config
| Function | Gas (max) |
| --- | --- |
| `setRollingApy` | 33,604 |
| `setRollingApyExternal` | N/A |
| `setDepositorLTV` | 34,079 |
| `setExternalBorrowCR` | N/A |
| `setMinDepositAmount` | 33,601 |
| `setMinLoanAmount` | 33,381 |
| `setMinTopupAmount` | 33,623 |
| `setDepositCap` | 33,415 |
| `setIsCapped` | 33,157 |
| `setMaxUserCount` | 33,629 |
| `setMaintenanceRate` | 36,177 |
| `setFlashLoanFee` | 33,797 |
| `setActionFees` | 57,164 |

### Pool Management - Whitelist & manager
| Function | Gas (max) |
| --- | --- |
| `addToWhitelist` | 59,556 |
| `removeFromWhitelist` | 37,803 |
| `setWhitelistEnabled` | 32,839 |
| `transferManager` | 29,161 |
| `renounceManager` | 28,648 |

### PositionManagementFacet
| Function | Gas (max) |
| --- | --- |
| `mintPositionWithDeposit` | 442,183 |

### FlashLoanFacet (includes onFlashLoan callback)
| Function | Gas (max) |
| --- | --- |
| `flashLoan` | 171,084 |

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
| `getActiveCreditIndex` | 8,785 |
| `getActiveCreditStates` | 16,204 |
| `getActiveCreditStatesByPosition` | 24,160 |
| `getActiveCreditStatus` | 13,026 |
| `getActiveCreditStatusByPosition` | 21,148 |
| `pendingActiveCredit` | 11,556 |
| `pendingActiveCreditByPosition` | 19,687 |
| `selectors` | 1,584 |

### ConfigViewFacet
| Function | Gas (max) |
| --- | --- |
| `getAumFeeInfo` | 6,797 |
| `getFixedTermConfigs` | 5,124 |
| `getFlashConfig` | 4,808 |
| `getImmutableConfig` | N/A |
| `getMaintenanceState` | 11,478 |
| `getManagedPoolConfig` | 38,789 |
| `getMinDepositAmount` | 4,606 |
| `getMinLoanAmount` | 4,540 |
| `getPoolCaps` | 7,141 |
| `getPoolConfig` | 36,517 |
| `getPoolInfo` | 40,692 |
| `getPoolList` | 45,080 |
| `getPoolManager` | 4,762 |
| `getPoolUnderlying` | 2,838 |
| `getRollingDelinquencyThresholds` | 2,995 |
| `isManagedPool` | 4,794 |
| `isPoolDeprecated` | 4,976 |
| `isWhitelistEnabled` | 4,960 |
| `isWhitelisted` | 18,695 |
| `selectors` | 5,203 |

### EnhancedLoanViewFacet
| Function | Gas (max) |
| --- | --- |
| `canOpenFixedLoan` | 39,714 |
| `getFixedLoanAccrued` | 11,376 |
| `getUserFixedLoansDetailed` | 24,808 |
| `getUserFixedLoansPaginated` | 23,845 |
| `getUserHealthMetrics` | 39,740 |
| `previewBorrowFixed` | 39,463 |
| `previewRepayFixed` | 9,428 |
| `selectors` | 1,776 |

### EqualIndexViewFacetV3
| Function | Gas (max) |
| --- | --- |
| `getIndexAssets` | 22,647 |
| `getIndexAssetCount` | 4,625 |
| `getProtocolBalance` | 242 |

### EqualLendDirectViewFacet
| Function | Gas (max) |
| --- | --- |
| `fillsRemaining` | 11,793 |
| `getBorrowerAgreements` | 16,123 |
| `getBorrowerOffer` | 24,881 |
| `getBorrowerOffers` | 18,745 |
| `getBorrowerRatioTrancheOffer` | 29,571 |
| `getLenderOffers` | 18,547 |
| `getOffer` | 27,331 |
| `getOfferSummary` | 30,230 |
| `getOfferTranche` | 12,821 |
| `getPoolActiveDirectLent` | 2,541 |
| `getPositionDirectState` | 17,756 |
| `getRatioBorrowerOffers` | 16,052 |
| `getRatioLenderOffers` | 21,042 |
| `getRatioTrancheOffer` | 29,842 |
| `getRatioTrancheStatus` | 16,222 |
| `getTrancheStatus` | 12,802 |
| `isTrancheDepleted` | 12,129 |
| `isTrancheOffer` | 4,901 |

### LiquidityViewFacet
| Function | Gas (max) |
| --- | --- |
| `getTotalPoolDeposits` | 4,591 |
| `getUserBalances` | 11,244 |
| `pendingYield` | 15,562 |
| `totalAvailableLiquidity` | 8,033 |
| `selectors` | 1,216 |

### LoanViewFacet
| Function | Gas (max) |
| --- | --- |
| `getRollingLoan` | 11,999 |
| `previewBorrowExternal` | N/A |
| `previewBorrowRolling` | 6,957 |
| `selectors` | 1,238 |

### MultiPoolPositionViewFacet
| Function | Gas (max) |
| --- | --- |
| `getMultiPoolPositionState` | 98,888 |
| `getPositionActivePools` | 37,213 |
| `getPositionAggregatedSummary` | 92,960 |
| `getPositionDirectAgreementIds` | 22,252 |
| `getPositionDirectAgreements` | 86,877 |
| `getPositionDirectSummary` | 45,359 |
| `getPositionDirectSummaryByAsset` | 84,893 |
| `getPositionPoolData` | 36,650 |
| `getPositionPoolDataPoolOnly` | 34,199 |
| `getPositionPoolMemberships` | 36,637 |
| `getPositionPoolStates` | 67,145 |
| `getUserPositions` | 16,382 |
| `isPositionMemberOfPool` | 10,775 |
| `selectors` | 3,389 |

### PoolUtilizationViewFacet
| Function | Gas (max) |
| --- | --- |
| `getPoolCapacity` | 13,063 |
| `getPoolStats` | 14,803 |
| `selectors` | 1,238 |

### PositionViewFacet
| Function | Gas (max) |
| --- | --- |
| `getLoansDetails` | 19,396 |
| `getPositionLoanIds` | 17,843 |
| `getPositionLoanSummary` | 31,297 |
| `getPositionMetadata` | 14,526 |
| `getPositionSolvency` | 22,256 |
| `getPositionState` | 51,556 |
| `isPositionDelinquent` | 15,832 |
| `selectors` | 1,959 |

### LoanPreviewFacet
| Function | Gas (max) |
| --- | --- |
| `selectors` | 1,363 |

### MaintenanceFacet
| Function | Gas (max) |
| --- | --- |
| `selectors` | 715 |

# EqualLend / EqualIndex Gas Estimates

_Generated on 2026-02-18 (UTC) via:_
- `forge test --match-path test/root/GasScenarioReport.t.sol --gas-report`
- `forge test --match-path "test/gas/*t.sol" --gas-report`
- `forge test --match-path test/derivatives/AmmAuctionGas.t.sol --gas-report`
- `forge test --match-path test/derivatives/MamCurveGas.t.sol --gas-report`
- `forge test --match-path test/derivatives/OptionsGas.t.sol --gas-report`
- `forge test --match-path test/derivatives/FuturesGas.t.sol --gas-report`
- `forge test --match-path test/derivatives/CommunityAuctionGas.t.sol --gas-report`
- `forge test --match-path test/derivatives/AmmAuctionGas.t.sol --match-test testGasSwapExactIn -vv`
- `forge test --match-path test/derivatives/MamCurveGas.t.sol --match-test testGasExecuteCurveSwap -vv`

_Sources of truth: `gas-report-scenarios.txt`, `gas-report-latest.txt`, `gas-report-derivatives.txt`._

## Methodology
- Scenario values come from `GasScenarioReport.t.sol` and represent end-to-end flows.
- Function-level values come from `test/gas/*t.sol`.
- Derivative swap `swap_only` values come from explicit `gasleft()` deltas logged in the two `-vv` runs.
- `N/A` means there is no active benchmark in the current suites for that function.

## Scenario Benchmarks (GasScenarioReport.t.sol)
### EqualIndex Flows
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Index creation w/ fee (`test_gas_IndexCreateWithFee`) | `EqualIndexFacetV3.createIndex` | **3,088,575** |
| Index mint only (`test_gas_IndexMintOnly`) | `EqualIndexFacetV3.mint` | **365,591** |
| Index burn only (`test_gas_IndexBurnOnly`) | `EqualIndexFacetV3.burn` | **154,870** |
| Index flash loan fee split (`test_gas_IndexFlashLoanFeeSplit`) | `EqualIndexFacetV3.flashLoan` | **138,145** |
| Index mint + burn (`test_gas_IndexMintBurnFlow`) | `EqualIndexFacetV3.mint + EqualIndexFacetV3.burn` | **12,574,544** |

### Pool Creation & Admin
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Minimal pool initialization (`test_gas_PoolInitMinimal`) | `PoolManagementFacet.initPool` | **811,680** |

### Position Management & Membership
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Mint + deposit (`test_gas_PositionMintAndDeposit`) | `PositionManagementFacet.mintPosition + depositToPosition` | **482,322** |
| Deposit only (`test_gas_PositionDepositOnly`) | `PositionManagementFacet.depositToPosition` | **252,033** |
| Withdraw only (`test_gas_PositionWithdrawOnly`) | `PositionManagementFacet.withdrawFromPosition` | **111,950** |
| Roll yield to principal (`test_gas_RollYieldToPosition`) | `PositionManagementFacet.rollYieldToPosition` | **102,292** |
| Close pool position (no commitments) (`test_gas_PositionClosePoolPosition`) | `PositionManagementFacet.closePoolPosition` | **109,759** |
| Deposit + withdraw + cleanup (`test_gas_PositionDepositWithdrawCloseCleanup`) | `PositionManagementFacet.depositToPosition + withdrawFromPosition + cleanupMembership` | **7,113,826** |

### Borrowing
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Open rolling borrow (`test_gas_BorrowRollingOnly`) | `LendingFacet.openRollingFromPosition` | **356,162** |
| Open fixed-term borrow (`test_gas_BorrowFixedOnly`) | `LendingFacet.openFixedFromPosition` | **592,432** |

### Loan Lifecycles
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling lifecycle (`test_gas_RollingLifecycle`) | `LendingFacet.openRollingFromPosition + makePaymentFromPosition + closeRollingCreditFromPosition` | **8,175,173** |
| Fixed lifecycle (`test_gas_FixedLifecycle`) | `LendingFacet.openFixedFromPosition + repayFixedFromPosition` | **8,382,849** |

### Direct Offers
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Post lender offer (`test_gas_DirectPostOfferOnly`) | `EqualLendDirectOfferFacet.postOffer` | **649,932** |
| Accept lender offer (`test_gas_DirectAcceptOfferOnly`) | `EqualLendDirectAgreementFacet.acceptOffer` | **1,085,867** |
| Post borrower offer (`test_gas_DirectPostBorrowerOfferOnly`) | `EqualLendDirectOfferFacet.postBorrowerOffer` | **630,246** |
| Accept borrower offer (`test_gas_DirectAcceptBorrowerOfferOnly`) | `EqualLendDirectAgreementFacet.acceptBorrowerOffer` | **1,090,737** |
| Direct offer repay flow (`test_gas_DirectOfferRepayFlow`) | `EqualLendDirectOfferFacet.postOffer + EqualLendDirectAgreementFacet.acceptOffer + EqualLendDirectLifecycleFacet.repay` | **45,645,161** |

### Penalties
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Rolling penalty (`test_gas_PenaltyRolling`) | `PenaltyFacet.penalizePositionRolling` | **5,848,784** |
| Fixed penalty (`test_gas_PenaltyFixed`) | `PenaltyFacet.penalizePositionFixed` | **5,972,202** |

### Derivative swap harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas (`swap_only`) |
| --- | --- | --- |
| AMM swap exact-in (`testGasSwapExactIn`) | `AmmAuctionFacet.swapExactIn` | **203,139** |
| MAM curve swap (`testGasExecuteCurveSwap`) | `MamCurveFacet.executeCurveSwap` | **255,375** |

### Options & Futures harnesses (test/derivatives/*Gas.t.sol)
| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Options create series (`testGasCreateOptionSeries`) | `OptionsFacet.createOptionSeries` | **817,113** |
| Options exercise (`testGasExerciseOptions`) | `OptionsFacet.exerciseOptions` | **200,272** |
| Futures create series (`testGasCreateFuturesSeries`) | `FuturesFacet.createFuturesSeries` | **817,456** |
| Futures settle (`testGasSettleFutures`) | `FuturesFacet.settleFutures` | **196,839** |

## Function-Level Gas Tests (test/gas/*t.sol)
### EqualIndexAdminFacetV3
| Function | Gas |
| --- | --- |
| `setIndexFees` | 76,606 |

### IndexToken (state-changing)
| Function | Gas |
| --- | --- |
| `mintIndexUnits` | 45,246 |
| `burnIndexUnits` | 35,057 |
| `recordMintDetails` | 77,010 |
| `recordBurnDetails` | 77,692 |
| `setFlashFeeBps` | 37,973 |

### IndexToken (views)
| Function | Gas |
| --- | --- |
| `assetsPaginated` | 22,072 |
| `bundleAmountsPaginated` | 21,970 |
| `previewMintPaginated` | 68,919 |
| `previewRedeem` | 73,450 |
| `previewRedeemPaginated` | 77,296 |
| `previewFlashLoanPaginated` | 32,203 |
| `isSolvent` | 33,258 |

### EqualIndexViewFacetV3 (views)
| Function | Gas |
| --- | --- |
| `getIndexAssets` | 32,641 |
| `getIndexAssetCount` | 12,943 |
| `getProtocolBalance` | 8,381 |

### Direct lifecycle
| Function | Gas |
| --- | --- |
| `exerciseDirect` | 210,120 |
| `callDirect` | 74,101 |

### Direct offer cancellations
| Function | Gas |
| --- | --- |
| `cancelOffer` | 102,399 |
| `cancelBorrowerOffer` | 110,746 |
| `cancelRatioTrancheOffer` | 91,080 |
| `cancelBorrowerRatioTrancheOffer` | 90,888 |
| `cancelOffersForPosition(uint256)` | 105,700 |
| `cancelOffersForPosition(bytes32)` | 102,702 |

### Rolling offers & lifecycle
| Function | Gas |
| --- | --- |
| `postRollingOffer` | 693,648 |
| `postBorrowerRollingOffer` | 700,509 |
| `acceptRollingOffer` | 1,149,424 |
| `cancelRollingOffer` | 92,094 |
| `makeRollingPayment` | 234,615 |
| `exerciseRolling` | 179,639 |
| `repayRollingInFull` | 236,396 |
| `recoverRolling` | 230,562 |

### Rolling views
| Function | Gas |
| --- | --- |
| `getRollingAgreement` | 47,252 |
| `getRollingOffer` | 38,018 |
| `getRollingBorrowerOffer` | 38,041 |
| `calculateRollingPayment` | 17,922 |
| `getRollingStatus` | 16,033 |
| `aggregateRollingExposure` | 30,037 |

### Limit order views
| Function | Gas |
| --- | --- |
| `getLimitOrder` | N/A |
| `getActiveLimitOrders` | N/A |
| `getLimitOrderEncumbrance` | N/A |
| `getLimitOrdersByPosition` | N/A |
| `getLimitOrderConfig` | N/A |

### Diamond loupe views
| Function | Gas |
| --- | --- |
| `facetAddress` | 15,717 |
| `facetAddresses` | 642,665 |
| `facetFunctionSelectors` | 464,191 |
| `supportsInterface` | 15,740 |

### EqualLendDirectViewFacet (views)
| Function | Gas |
| --- | --- |
| `fillsRemaining` | 19,945 |
| `getBorrowerAgreements` | 27,432 |
| `getBorrowerOffer` | 34,730 |
| `getBorrowerOffers` | 29,929 |
| `getBorrowerRatioTrancheOffer` | 39,093 |
| `getLenderOffers` | 29,621 |
| `getOffer` | 36,959 |
| `getOfferSummary` | 45,615 |
| `getOfferTranche` | 22,165 |
| `getPoolActiveDirectLent` | 11,202 |
| `getPositionDirectState` | 30,228 |
| `getRatioBorrowerOffers` | 27,008 |
| `getRatioLenderOffers` | 32,388 |
| `getRatioTrancheOffer` | 39,929 |
| `getRatioTrancheStatus` | 25,487 |
| `getTrancheStatus` | 21,931 |
| `isTrancheDepleted` | 20,724 |
| `isTrancheOffer` | 13,364 |

### Pool Management - Initialization
| Function | Gas |
| --- | --- |
| `initPoolWithActionFees` | 319,316 |
| `initManagedPool` | 738,538 |

### Pool Management - Managed config
| Function | Gas |
| --- | --- |
| `setRollingApy` | 37,440 |
| `setRollingApyExternal` | N/A |
| `setDepositorLTV` | 38,179 |
| `setExternalBorrowCR` | N/A |
| `setMinDepositAmount` | 37,569 |
| `setMinLoanAmount` | 37,591 |
| `setMinTopupAmount` | 37,503 |
| `setDepositCap` | 37,691 |
| `setIsCapped` | 37,191 |
| `setMaxUserCount` | 37,487 |
| `setMaintenanceRate` | 40,497 |
| `setFlashLoanFee` | 38,183 |
| `setActionFees` | 61,718 |

### Pool Management - Whitelist & manager
| Function | Gas |
| --- | --- |
| `addToWhitelist` | 63,497 |
| `removeFromWhitelist` | 37,164 |
| `setWhitelistEnabled` | 37,137 |
| `transferManager` | 33,415 |
| `renounceManager` | 32,579 |

### PositionManagementFacet
| Function | Gas |
| --- | --- |
| `mintPositionWithDeposit` | 454,105 |

### FlashLoanFacet (includes onFlashLoan callback)
| Function | Gas |
| --- | --- |
| `flashLoan` | 187,284 |

### FeeFacet (views)
| Function | Gas |
| --- | --- |
| `getPoolActionFee` | 13,514 |
| `getIndexActionFee` | 13,533 |
| `previewActionFee` | 13,101 |
| `previewIndexActionFee` | 13,117 |
| `getPoolActionFees` | 35,086 |
| `previewActionFees` | 33,056 |

### ActiveCreditViewFacet
| Function | Gas |
| --- | --- |
| `getActiveCreditIndex` | 17,293 |
| `getActiveCreditStates` | 27,279 |
| `getActiveCreditStatesByPosition` | 34,993 |
| `getActiveCreditStatus` | 23,697 |
| `getActiveCreditStatusByPosition` | 32,039 |
| `pendingActiveCredit` | 22,148 |
| `pendingActiveCreditByPosition` | 30,037 |
| `selectors` | 11,144 |

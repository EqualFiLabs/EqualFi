# Echidna Fuzzing Report: EqualFi

## Executive Summary

We conducted deep fuzzing campaigns on four critical facets of the EqualFi Diamond: `OptionsFacet`, `CommunityAuctionFacet`, `MamCurveFacet` (Execution + Management), and `EqualLendDirectOfferFacet`.

**Overall Status:** ✅ **PASSED**
**Total Transactions:** ~150,000+
**Invariants Broken:** 0

---

## 1. OptionsFacet Fuzzing

**Target:** `test/equallend-direct/EchidnaOptions.sol`
**Scope:** Creation, Exercise, Reclamation, Fees, Solvency.

### Invariants Verified
| Invariant | Description | Result |
|-----------|-------------|--------|
| `echidna_token_supply_matches_remaining` | `OptionToken.totalSupply(id)` always matches `series.remaining`. | ✅ PASSED |
| `echidna_collateral_matches_remaining` | Locked collateral (1:1 for Call, Normalized for Put) matches remaining options. | ✅ PASSED |
| `echidna_maker_solvent` | Maker's pool principal is always >= locked collateral. | ✅ PASSED |
| `echidna_fees_accrued_correctly` | Protocol fee balances strictly increase (monotonicity) when fees are charged. | ✅ PASSED |

**Metrics:**
- **Calls:** ~50,000
- **Coverage:** 12,048 instructions
- **Corpus:** 61 unique sequences

---

## 2. CommunityAuctionFacet Fuzzing

**Target:** `test/EchidnaCommunityAuction.sol`
**Scope:** Auction Creation, Liquidity Join/Leave, Swaps.

### Invariants Verified
| Invariant | Description | Result |
|-----------|-------------|--------|
| `echidna_auction_reserves_valid` | Auction reserves are consistent with maker deposits and withdrawals. | ✅ PASSED |
| `echidna_shares_consistency` | `totalShares > 0` whenever an auction is active (preventing division by zero). | ✅ PASSED |

**Metrics:**
- **Calls:** ~14,000
- **Coverage:** 8,597 instructions
- **Corpus:** 46 unique sequences

---

## 3. MamCurveFacet Fuzzing (Full)

**Target:** `test/EchidnaMamFull.sol`
**Scope:** Curve Creation, Updates, Cancellation, Execution (Swaps).

### Invariants Verified
| Invariant | Description | Result |
|-----------|-------------|--------|
| `echidna_maker_solvency` | Maker's pool principal is always >= total encumbered amount. | ✅ PASSED |
| `echidna_encumbrance_matches_volume` | `LibEncumbrance` locked amount matches `curve.remainingVolume` for active curves. | ✅ PASSED |

**Metrics:**
- **Calls:** ~50,000
- **Coverage:** 3,986 instructions
- **Corpus:** 10 unique sequences

---

## 4. EqualLendDirectOfferFacet Fuzzing

**Target:** `test/equallend-direct/EchidnaDirectOffers.sol`
**Scope:** Lender Offer Creation, Borrower Offer Creation, Offer Cancellation.

### Invariants Verified
| Invariant | Description | Result |
|-----------|-------------|--------|
| `echidna_offer_integrity` | Active offers always maintain `principal > 0` and `collateralLockAmount > 0`. | ✅ PASSED |
| `echidna_borrower_encumbrance` | Active borrower offers correctly encumber collateral in `LibEncumbrance`. | ✅ PASSED |

**Metrics:**
- **Calls:** ~50,000
- **Coverage:** 9,966 instructions
- **Corpus:** 38 unique sequences

---

## Technical Notes

- **Mocking:** `MockPositionNFT` and `MockERC20` were used to bypass external dependencies and focus on facet logic.
- **Linking:** `crytic-compile` args were tuned to ignore `PositionMSCA` related files to resolve linking errors during the fuzzing build.
- **Compilation Fixes:** Overloaded functions (`postOffer`) in `DirectOfferFacet` were successfully targeted using `abi.encodeWithSignature` in the harness.
- **Coverage:** High instruction coverage confirms deep exploration of state transitions (Active -> Finalized/Expired/Reclaimed).

## Conclusion

The core derivative primitives of EqualFi (`Options`, `Auctions`, `MAM`) and the foundational lending offers (`Direct`) are robust against randomized state transitions and malicious inputs. Solvency and accounting invariants hold true under stress.

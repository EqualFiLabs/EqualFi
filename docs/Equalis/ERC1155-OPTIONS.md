# Fully Collateralized Options via ERC-1155 Tokens

**Version:** 2.1 (Aligned with current `OptionsFacet` behavior)

The implementation treats Options and Futures not as ephemeral contracts, but as **tokenized claims on locked collateral**. This differs from traditional DeFi options in a few critical ways:

1. **ERC-1155 "Physical" Tokens:**
The `OptionToken.sol` is an ERC-1155 contract. Each `seriesId` corresponds to a specific Option Series (Strike, Expiry, Underlying). The token itself represents the **Long** side of the contract.
2. **Flash Accounting & Collateralization:**
When a Maker creates a series, the collateral is locked inside their **Position NFT** using `LibDerivativeHelpers._lockCollateral`. The assets never leave the pool; they are just flagged as encumbered. This allows the collateral to theoretically continue earning `FeeIndex` yield (passive lending yield) while backing the option, maximizing capital efficiency.
3. **Reclaim Constraint (Owner + Remaining Supply):**
`reclaimOptions` is controlled by ownership of the maker's Position NFT (`makerPositionId`) and remaining token supply.
* To unlock collateral after expiry, the **current owner of the maker Position NFT** must call `reclaimOptions`.
* If `remaining > 0`, caller must hold and burn that remaining `OptionToken` balance.
* If `remaining == 0` (all options exercised), reclaim finalizes the series without additional burns.
* **Implication:** If a writer sells unexercised options, they (or a later NFT owner) must reacquire remaining tokens to unlock residual collateral.
4. **Native ETH Support:**
The system supports native ETH (`address(0)`) as underlying or strike asset via `LibCurrency`. During exercise, payment is pulled through `LibCurrency.pullAtLeast`.
* For native-ETH payment legs, `msg.value` must equal `maxPayment` (not strictly the previewed minimum), and must still satisfy the required minimum payment.
* Native ETH transfers use low-level calls with error handling.



---

### Concrete Examples: How to Construct Positions

#### 1. Covered Call (Short Call)

* **Goal:** Earn premium on ETH you already own; neutral-to-bullish view.
* **Mechanism:** You act as the **Maker**.
* **Step 1: Create Series**
Call `createOptionSeries` on `OptionsFacet`:
* `underlyingAsset`: WETH
* `strikeAsset`: USDC
* `strikePrice`: 3000 USDC (Scaled 1e18)
* `isCall`: `true`
* `collateral`: 1 WETH


* **Result:**
* 1 WETH is locked in your Position NFT encumbrance (`directLocked`).
* You receive **1 unit** of `OptionToken` (ERC-1155) representing the Long Call.


* **Step 2: Open "Short"**
* You **Sell** the `OptionToken` on a secondary market (or via an internal `AmmAuction`) to a buyer.
* The cash you receive is your **Premium**.


* **Outcome:**
* **Exercised:** You keep the Premium. The protocol swaps your 1 WETH for the 3000 USDC strike payment.
* **Expired:** You keep the Premium. You must acquire the worthless token to unlock your 1 WETH.



#### 2. Long Call

* **Goal:** Leveraged upside on ETH; bullish view.
* **Mechanism:** You act as the **Taker**.
* **Step 1: Acquire**
* Buy the `OptionToken` (minted by a Maker above) from the market.


* **Step 2: Exercise (If ITM)**
Call `exerciseOptions` on `OptionsFacet`:
* `seriesId`: The ID of the token you hold.
* `amount`: 1.
* `maxPayment`: Maximum you are willing to pay (must be >= required payment).


* **Result:**
* You send **3000 USDC** (Strike) to the protocol.
* You burn **1 OptionToken**.
* The protocol sends you **1 WETH** (Collateral).


* **Net Profit:** Value of 1 WETH - 3000 USDC - Premium Paid.

#### 3. Secured Put (Short Put)

* **Goal:** Earn yield on idle USDC; willingness to buy ETH at a discount.
* **Mechanism:** You act as the **Maker**.
* **Step 1: Create Series**
Call `createOptionSeries`:
* `underlyingAsset`: WETH
* `strikeAsset`: USDC
* `isCall`: `false` (Put)
* `strikePrice`: 2500 USDC
* `collateral`: 2500 USDC (Calculated by `_normalizeStrikeAmount`).


* **Result:**
* 2500 USDC is locked in your Position NFT.
* You receive **1 OptionToken** (Long Put).


* **Step 2: Open "Short"**
* Sell the `OptionToken`. Receive Premium.


* **Outcome:**
* **Exercised (ETH < 2500):** You keep Premium. You pay 2500 USDC and receive 1 WETH (effectively buying ETH at 2500).
* **Expired:** You keep Premium + 2500 USDC after reclaiming (which requires burning any remaining option supply).



#### 4. Long Put

* **Goal:** Hedge ETH exposure or speculate on downside.
* **Mechanism:** You act as the **Taker**.
* **Step 1: Acquire**
* Buy the `OptionToken` (Put) from the market.


* **Step 2: Exercise (If ITM)**
Call `exerciseOptions`:
* You send **1 WETH** (Underlying) to the protocol.
* You burn **1 OptionToken**.
* You pass `maxPayment` to cap payment input.


* **Result:**
* The protocol sends you **2500 USDC** (Collateral).


* **Net Profit:** 2500 USDC - Value of 1 WETH - Premium Paid.

### Summary of Flows

| Strategy | User Role | Action in `OptionsFacet` | Collateral Locked | Token Held |
| --- | --- | --- | --- | --- |
| **Short Call** | Maker | `createOptionSeries` (`isCall=true`) | Underlying (ETH) | Sold to Market |
| **Long Call** | Taker | `exerciseOptions` | None | Held (Burned on exercise) |
| **Short Put** | Maker | `createOptionSeries` (`isCall=false`) | Strike (USDC) | Sold to Market |
| **Long Put** | Taker | `exerciseOptions` | None | Held (Burned on exercise) |

---

## Native ETH Considerations

When using native ETH as the underlying or strike asset:

### Creating Options with Native ETH Collateral
- For covered calls on native ETH, the maker's ETH is locked via `LibEncumbrance.directLocked`
- The ETH remains in the protocol's tracked balance (`nativeTrackedTotal`)

### Exercising Options with Native ETH
- **Call Exercise (ETH underlying)**: Holder pays strike in quote asset, receives native ETH via `LibCurrency.transferWithMin()`
- **Put Exercise (ETH strike)**: Holder pays underlying, receives native ETH strike amount
- All native ETH transfers use low-level `call{value: amount}("")` with proper error handling

### Payment with Native ETH
- When the payment asset is native ETH in exercise flows, users send `msg.value == maxPayment`
- `maxPayment` must be at least the required payment amount; otherwise exercise reverts
- Mismatch in expected value reverts with `UnexpectedMsgValue`

---

## Additional Behavior Notes

- **Exercise windows matter**:
  - American options: exercisable strictly before expiry.
  - European options: exercisable only inside the configured tolerance window around expiry.
- **Fee model is configurable per series creation**:
  - Create, exercise, and reclaim fees (bps + optional flat wad) can use defaults or custom values (bounded by config min/max).

---

**Document Version:** 2.1
**Last Updated:** February 2026

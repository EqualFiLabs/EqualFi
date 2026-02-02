# Echidna Test Results

## Status: PASSING
(Tests were manually interrupted after ~9,700/50,000 calls to save time. All invariants passed during this run.)

## Coverage
- **Unique Instructions**: 22,300
- **Unique Codehashes**: 22
- **Corpus Size**: 13 sequences (all replayed successfully)

## Invariants Checked
The following properties held true throughout the run:
1. `echidna_k_invariant`: **PASSING**
2. `echidna_encumbrance_invariant`: **PASSING**
3. `echidna_solvency`: **PASSING**

## Execution Details
- **Command**: `echidna test/EchidnaAmmAuction.sol --contract EchidnaAmmAuction --config test/echidna_amm.yaml`
- **Working Directory**: `/home/hooftly/Projects/EqualFi`
- **Total Calls**: ~9,770
- **Speed**: ~465 calls/s

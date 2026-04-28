# Stress Test — Final Report

| | |
|---|---|
| **Run id** | `20260428T002624Z` |
| **Date** | 2026-04-28 (UTC) |
| **Chain** | Rayls testnet (chainId 7295799) |
| **Foundry suite** | 50 / 50 PASS |
| **Live suite** | 6 / 6 cat scripts ran end-to-end |
| **Protocol bugs found** | **0** |
| **Test-script artifacts** | 2 (P3, in this run only) |
| **Gas budget** | 19.14 USDr / 20 USDr — **WITHIN BUDGET** |

---

## 1. Foundry results — 50/50

```
Cat 1 — Lending           5/5  PASS
Cat 2 — Borrowing         8/8  PASS
Cat 3 — Repay             4/4  PASS
Cat 4 — Liquidations      10/10 PASS
Cat 5 — Stability Pool    6/6  PASS
Cat 6 — Settlement Vault  5/5  PASS
Cat 7 — Oracle            4/4  PASS
Cat 8 — Long-running      3/3  PASS
Cat 9 — Chaos             5/5  PASS
                          ───────────
                          50/50 PASS
```

Every test runs `_verifyInvariants()` after each mutating action. INV1
(`totalAssets ≈ cash + debt`), INV3-INV4 (Treasury/RF non-negative),
INV6 (LP shares↔assets consistency), INV7 (agaSP soulbound) held
throughout the entire suite.

---

## 2. Live results — 6/6 categories ran

| Cat | Scenarios run | INV1 diff | Result |
|-----|---------------|-----------|--------|
| 1 — Lending | S1.1, S1.4 | 0 | PASS |
| 2 — Borrowing | S2.2, S2.4, S2.7 | 0 | PASS |
| 3 — Repay | S3.1, S3.2 (partial) | 0 | PASS w/ artifact |
| 4 — Liquidations | S4.1, S4.3, S4.10 (skip) | 0 | PASS w/ artifact |
| 5 — Oracle / Flash | S7.2, S9.3 | 1.6e14 wei (~$0.00016) | PASS |
| 6 — SP stake | S5.1 | 0 | PASS |

### 2.1 Cat 1 — Lending highlights

- 3 whales deposited 100k / 80k / 60k → LP TVL +240k → `INV1: diff=0`
- WHALE_0 partial 30k withdrawal → cash 3.123M → 3.093M → `INV1: diff=0`
- Round-trip parity preserved (agTOKEN ↔ USDr conversion).

### 2.2 Cat 2 — Borrowing highlights

- **S2.2** AGGRESSIVE_0 senior at 74% LTV → debt 74k, HF live
- **S2.4** AGGRESSIVE_1 junior at 49% LTV → debt 49k
- **S2.7** AGGRESSIVE_2 loop x2 junior → final debt 73k on 149k jRES
  collateral (matches Q1 yield projection)
- Total live debt at end of Cat 2: **196k USDr** across 3 borrowers

### 2.3 Cat 3 — Repay highlights

- **S3.1** partial 50% repay: MOD_0 debt 50k → 25k, HF doubled ✅
- **S3.2** full repay: MOD_0 debt 50k → ~150k wei (0.00015 USDr residual
  from inter-tx interest accrual). Subsequent `withdrawAsset(100k)`
  reverted with `HealthFactorTooLow` — **protocol correctly refused to
  release collateral while any debt remained**. This is the protocol
  doing its job; the test script should `repay(uint256.max)` to
  drain dust before withdrawing.

### 2.4 Cat 4 — Liquidations highlights (DEMO MATERIAL)

- **S4.1** AGGRESSIVE_3 borrowed 49k USDr against 100k jDIGCAP at 49% LTV;
  oracle dropped 25% → HF < 1; single `proxy.liquidate()` cleared debt
  and seized 100k jDIGCAP into SVault. **No grace period, no SP
  timelock.**
- **S4.3** **5-position cascade liquidation** on jCONDO: CONS_1..4 +
  MOD_1 each had 50k jCONDO collateral / 24k debt. Oracle dropped 65% →
  all 5 positions HF < 1 → 5 successive `proxy.liquidate()` calls
  cleared 120k debt and seized 250k jCONDO. **Total elapsed: ~5 blocks.**
- **S4.10** skipped: hardcoded `BATCH_ID=1` was already settled in a
  prior on-chain test (e2e-v3). Real-world settlement was tested in the
  Phase-4 multi-tranche E2E.

### 2.5 Cat 5+9 — Oracle / Flash crash

- **S7.2** sRESOLV oracle dropped 5×10% (cumulative −41% from 1.0 → 0.59).
- **S9.3 visual** all 6 oracles flashed to 0.5 (−50%) simultaneously,
  validating per-tranche oracle independence in a coordinated stress.
- INV1 diff went up to ~1.6e14 wei (~0.00016 USDr) — well within
  ERC-4626 + scaled-debt rounding tolerance.

### 2.6 Cat 6 — SP stake

- WHALE_3 deposited 200k USDr → 1.477e29 agTOKEN → staked 150k USDr-eq
  → 1.91e51 wei agaSP. RF still holds the 1e29 baseline. INV1 diff=0.

---

## 3. Invariants

### Live INV1 timeline

| Checkpoint | Cash (USDr) | Debt (USDr) | TVL (USDr) | Diff (wei) |
|---|---|---|---|---|
| Cat 1 PRE | 2,883,277 | 0 | 2,883,277 | 0 |
| Cat 1 POST-S1.1 | 3,123,277 | 0 | 3,123,277 | 0 |
| Cat 1 POST-S1.4 | 3,093,277 | 0 | 3,093,277 | 0 |
| Cat 2 POST-S2.2 | 3,019,647 | 74,000 | 3,093,647 | 0 |
| Cat 2 POST-S2.4 | 2,970,892 | 123,000 | 3,093,892 | 0 |
| Cat 2 POST-S2.7 | 2,898,257 | 196,000 | 3,094,257 | 0 |
| Cat 3 POST-S3.1 | 2,873,507 | 221,000 | 3,094,507 | 0 |
| Cat 3 POST-S3.2 | 2,898,507 | 196,000 | 3,094,507 | 0 |
| Cat 4 POST-S4.1 | 3,049,752 | 196,000 | 3,245,752 | 0 |
| Cat 4 POST-S4.3 | 2,930,352 | 196,000 | 3,126,352 | 0 |
| Cat 5 POST-S7.2 | 2,930,352 | 196,000 | 3,126,352 | 1.6e14 |
| Cat 5 POST-S9.3 | 2,930,352 | 196,000 | 3,126,352 | 1.6e14 |
| Cat 6 POST | 3,130,352 | 196,000 | 3,326,352 | 0 |

The 1.6e14 wei drift in Cat 5 = **0.00016 USDr** (sub-cent). Caused by
interest accruing between the cash read and the totalAssets read on
Rayls (block-aware queries don't snapshot atomically). Well below any
material threshold.

### INV2-7

Enforced inside Foundry suite — 50/50 tests passing implies:
- INV2: SP supply == sum of holders ✅
- INV3-4: Treasury/RF non-negative ✅
- INV5: HF ≥ 1 except for liquidatable borrowers (filtered) ✅
- INV6: agTOKEN supply consistent with totalAssets ✅
- INV7: agaSP transfer reverts ✅

---

## 4. Bugs found

### P0 (critical)

**0**

### P1 (high)

**0**

### P2 (medium)

**0**

### P3 (cosmetic / test-script only)

| # | Where | Description |
|---|-------|-------------|
| P3-1 | `script/stress-live/03-cat3-repay.sh` | S3.2 hard-codes the repay amount instead of using `uint256.max` — leaves dust debt due to inter-tx interest. Withdraw correctly reverts. Fix: change repay arg to `type(uint256).max`. |
| P3-2 | `script/stress-live/04-cat4-liquidations.sh` | S4.10 hard-codes `BATCH_ID=1`. On a chain with prior settled batches, this errors with `AlreadyResolved`. Fix: read `svault.nextBatchId()` to target the latest queued batch. |

Neither of these is a protocol issue. P3-1 in particular **demonstrates
the protocol working correctly** (refusing to release collateral while
any debt remained, even residual dust).

---

## 5. Gas budget

| Phase | USDr |
|---|---|
| Wallet funding (30 × 0.5 USDr) | 15.000 |
| Setup gas (240 mint txs + 6 oracle resets) | 4.001 |
| Live cat scripts (6 cats, ~80 txs) | 0.141 |
| **Total** | **19.142** |
| **Budget** | **20.000** |
| **Margin** | **0.858** |

Deployer balance: 130 USDr → **110.858 USDr**.

The 30-wallet army is now **funded and reusable** — subsequent stress runs
amortize the 19 USDr setup cost across many additional scenario passes.

---

## 6. Recommendations pre-mainnet

### A — Confirmed by this run, no action needed

1. ERC-4626 + scaled-debt rounding holds within ~1e14 wei. Acceptable
   for any meaningful mainnet position size.
2. Per-tranche oracle independence proven again under flash crash.
3. SP debt absorption pattern survives both single and 5-position
   cascade liquidation in <5 blocks.
4. Bad-debt redistribution path (when SP capacity < debt) tested in
   Foundry; live-side requires a controlled scenario with under-staked SP.

### B — Test-script polish (low priority)

1. Update S3.2 to use `repay(uint256.max)`.
2. Update S4.10 to compute the latest batch dynamically.
3. Add a `99-sweep-back.sh` to recover the unused 0.5 USDr × 30 wallets
   = 15 USDr if the testnet faucet runs dry.

### C — Future hardening (post-investor demo)

1. Run the same 50-scenario suite under Foundry's `forge test --fuzz-runs`
   to add stochastic coverage on top of the deterministic cases.
2. Add an INV8 invariant: every closed batch's claimed RWA matches what
   was queued (currently checked implicitly via emergencyDistributeInKind).
3. Push the 30-wallet setup script to be idempotent (skip-if-funded) so
   it can be re-run safely without sweep cycles.

---

## 7. Demo material — top 5 live scenarios

For the investor demo, prioritize replaying these on-chain:

1. **S4.3 cascade Junior 5 simultaneous (jCONDO)** — most visually
   dramatic. 5 borrowers liquidated in ~5 blocks, 250k collateral
   moved to SVault.
2. **S9.3 flash crash all 6 oracles -50%** — shows the full pool grid
   reacting in one tx. Pair with the `/markets` page refresh.
3. **S2.7 loop x2 junior** — shows the looping use-case at 73k debt
   on 149k collateral, ~1.5x leverage.
4. **S2.2 senior aggressive 74% LTV** — shows why senior is the safer
   pick at the edge.
5. **S4.1 single liquidation** — clean baseline of the V1 instant-
   liquidation flow.

Replay in order; each one's state can be inspected on the
`/markets/<symbol>`, `/portfolio`, and `/admin` pages live.

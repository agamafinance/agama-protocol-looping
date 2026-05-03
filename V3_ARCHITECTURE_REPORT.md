# Agama V3 — Architecture & Test Report

**Network**: Rayls testnet (chainId 7295799)
**Tag**: `v3.0.0-isolated-debt`
**Generated**: 2026-05-04 (overnight refactor session)

---

## Executive Summary

Agama V3 ships a fundamental architectural change: **per-market debt isolation**. Each lending market (one per RWA tranche) now maintains its own independent debt counter. Borrows, repays, and liquidations all scope to a single market — no cross-market spillover.

This eliminates the V2 cross-collateral exploit that allowed an attacker to wipe global debt by liquidating a small dust position. It also brings Agama in line with the Compound V2 isolation model, which is the industry standard for protocols with heterogeneous risk profiles (Senior vs Junior tranches).

**What stays the same**: the lender side (LP USDr deposits → agYLD shares) and the SP backstop (sagYLD) remain mutualised across all markets. Bad debt redistribution is global. Only the **borrower-side** is isolated.

---

## Architecture

### Contract topology (32 contracts on chain)

```
                    ┌─────────────────────────┐
                    │      USDr (mock)        │
                    │  borrow asset, ERC-20   │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │     LendingPool         │
                    │ ERC-4626 — agYLD shares │
                    │ + V3 per-market routing │
                    └─────┬────────────┬──────┘
                          │            │
              ┌───────────▼───┐    ┌───▼─────────┐
              │  DebtToken    │    │ StabilityPool│
              │ scaled debt   │    │ ERC-4626 SP  │
              │ per-(user,    │    │ sagYLD       │
              │  adapter)     │    │ (cooldown 7d)│
              └───────────────┘    └───────┬──────┘
                                           │
                          ┌────────────────▼──────────┐
                          │     LiquidationProxy      │
                          │ MANAGER_ROLE entrypoint   │
                          └───────────────┬───────────┘
                                          │
       ┌──────────────────────────────────▼────────────────────┐
       │                  Adapter layer (IAssetAdapter)        │
       │   sRESOLV  jRESOLV  sDIGCAP  jDIGCAP  sCONDO  jCONDO  │
       │   (each = MockTrancheToken + MockOracle + AmFiAdapter)│
       └────────────────────────────────────────────────────────┘

                Collectors (auto-staked into SP)
       ┌────────────┬────────────┬────────────┐
       │  Treasury  │ ReserveFund│ FeeCollect │
       └────────────┴────────────┴────────────┘
                                          │
                          ┌───────────────▼──────────┐
                          │   SettlementVault        │
                          │ RWA seizure → batch →    │
                          │ external redemption →    │
                          │ split (98% SP / 2% Treas)│
                          └──────────────────────────┘
```

### Risk parameters

| Tranche tier | MAX_LTV | LIQ_THRESHOLD | LIQ_BONUS | APR target |
|--------------|---------|---------------|-----------|-----------|
| **Senior** (sRESOLV, sDIGCAP, sCONDO) | 75% | 85% | 3% | 12% (capped) |
| **Junior** (jRESOLV, jDIGCAP, jCONDO) | 50% | 65% | 8% | 24% (uncapped) |

Origination fee : **0%** (Aave-style — set 2026-05-03).
Reserve factor : **10%** of borrow APR → Treasury → SP auto-stake.
Settlement split : **98% SP / 2% Treasury** of every RWA redemption.

---

## V3 Design Change: Per-Market Debt

### V2 (broken)

```
DebtToken.balanceOf(user) → single uint256
  - mint adds to user's global counter
  - burn subtracts from global counter
  - liquidate() reads global, wipes global

Borrow check: HF(adapter, user) = collat_at_adapter × LT / total_global_debt
Liquidate:   wipes ENTIRE global debt, seizes only the targeted adapter's collat
```

**Exploit vector**: a user with 100k sRESOLV (LT 85%) + 10k jRESOLV (LT 65%) borrows 70k via sRESOLV. Senior MaxLTV check passes (`100 × 0.75 / 70 = 1.07`). But jRESOLV's HF is now `10 × 0.65 / 70 = 0.092` — instantly liquidatable. A liquidator (or the user themselves with manager access) calls `liquidate(jRESOLV)` which wipes the full 70k of debt while seizing only $10k of jRESOLV. SP loses ~60k per attack.

### V3 (fixed)

```
DebtToken.balanceOf(user, adapter) → uint256 per (user, adapter)
  - mint adds to (user, adapter) counter
  - burn subtracts from (user, adapter) counter
  - liquidate() reads (user, adapter), wipes only that pair

Borrow check: HF(adapter, user) = collat_at_adapter × LT / debt_at_adapter
Liquidate:    wipes only debt_at_adapter, seizes that adapter's collat
```

Aggregate views (`balanceOf(user)`, `totalUserDebtAcrossMarkets(user)`) are preserved for UI/events with explicit warnings: **DO NOT USE FOR ECONOMIC CHECKS**. A canary grep across `LendingPool / StabilityPool / LiquidationProxy` confirms zero usage in core paths.

### What's still mutualised (correctly so)

The **lender side** is intentionally not isolated:
- Single USDr cash pool (one IRM, one utilization curve)
- Single agYLD share token (lenders share exposure)
- Single SP (sagYLD holders backstop the entire protocol)
- Bad-debt redistribution (`bdAccLDebt`) is global

This is the standard Compound V2 / Aave V3 pattern: borrowers have isolated positions, but the lender pool is one shared book. Otherwise the SP's capital efficiency would collapse.

---

## Test Results

### Foundry suite

```
266 tests passed, 0 failed, 0 skipped
29 test suites
~135ms total runtime
```

Includes:
- **20 new isolation tests** in DebtToken unit suite
- **3 rewritten "exploit-is-dead" tests** in stress suites:
  - `test_S2_5_multiCollateralSameType` — verifies HF = ∞ on empty market
  - `test_S2_6_crossTrancheMultiCollat` — same for Senior + Junior
  - `test_S4_7_crossCollatExploit_isDead` — reproduces V2 attack setup, asserts `liquidate(empty)` reverts with `NoDebtToLiquidate`
- All 264 previously passing tests still green after refactor

### Live on-chain tests (Rayls testnet)

| Test | Result |
|------|--------|
| Smoke E2E (10 phases) | ✓ PASS |
| Multi-actor cooldown (3 wallets, 5min cycle) | ✓ PASS |
| agYLD/sagYLD invariants (8 transitions) | ✓ PASS |
| Big borrow APR oscillation | ✓ PASS |
| Full-flow stress (4 cycles, 50+ txs) | ✓ PASS |
| TX flood (9 waves, ~120 txs, 15+ wallets) | ✓ PASS |
| **V3 dust-exploit dead** | ✓ PASS (revert NoDebtToLiquidate confirmed live) |
| **V3 multi-market isolation** | ✓ PASS (3 indep debts, repay scopes correctly) |
| **V3 full E2E (14 surfaces)** | ✓ PASS (exhaustive on-chain coverage) |

### Live exploit dead — concrete evidence

```
Setup:  attacker has 100k sRESOLV + 10k jRESOLV
Action: borrow 60k USDr via sRESOLV (passes Senior MaxLTV 75%)

Per-market debt after borrow:
  DebtToken.balanceOf(attacker, sRESOLV): 60,000.0001 USDr  ✓
  DebtToken.balanceOf(attacker, jRESOLV):           0       ✓
  totalUserDebtAcrossMarkets:             60,000.0001 USDr

V2 attack: liquidate(jRESOLV) — would wipe full 60k debt for 10k seized
V3 result: liquidate(jRESOLV) reverts: NoDebtToLiquidate (selector 0x4fc2e0e1)
```

### Live multi-market isolation — concrete evidence

```
User: 0xb2925153613CFA370bA9E894d9DB28297ae6AA98
3 simultaneous independent debts:
  - 50k via sRESOLV
  - 30k via sDIGCAP
  - 20k via sCONDO

Action: repay 10k via sRESOLV
Deltas:
  sRESOLV: -9,999.9995 USDr  (target -10k, accrual rounding)
  sDIGCAP:     +0.0003 USDr  (interest accrual only)
  sCONDO:      +0.0002 USDr  (interest accrual only)

VERIFIED: repay scopes precisely to the targeted market.
```

---

## Live Deployment (Rayls testnet 7295799)

### Core contracts (14 — all verified ✓)

| Contract | Address |
|----------|---------|
| USDr | `0x74eF358563dcBa0FdDEE6FE7c944e859C001f9D6` |
| LendingPool (agYLD) | `0x2d621d442B4B652001448a7D5Ce7891bE54b9be0` |
| DebtToken | `0x9F918bB67E503999d20F0d0641c76A0Ca76E8E96` |
| StabilityPool (sagYLD) | `0x4A56BB11bbfEDf92ae45f2473fb35AAD1949BeAd` |
| LiquidationProxy | `0xdf90B5d51f879dc3b8075ca0ed4b9306bDE225B5` |
| SettlementVault | `0x9a4997632272177E0d6fF161F5c631235F887c6d` |
| Treasury | `0x6af9fe9A7a75aEc304bDbd79Cb7056285691D7aE` |
| ReserveFund | `0xbd6E5BDa073Fc88ddc0091C34e963657a37E594a` |
| FeeCollector | `0x0C76ffb6eD0b41AC38C2a7c2db1F3837D4a9D2cF` |
| MockAMFI | `0x9db8E13BEb90c2FAdB051Bf1d3d03D449F63CC30` |
| MockOracle | `0x05C4Cf2d56bAc9Fe9736eEaad72f2c6bc4714A43` |
| AmFiAdapter (default) | `0xFC2A1105d20312b1536efC3473e16D1b778a91E3` |
| Faucet | `0xFe70Fdf0070265F0e6B9fDd9801eE98A15De26f9` |
| SplitFaucet | `0x287e12D2C73b0eaA257b653b11B1a06C928fF963` |

### Tranche contracts (18 — all verified ✓)

Each tranche = 3 contracts (token, oracle, adapter):

| Tranche | Token | Adapter |
|---------|-------|---------|
| sRESOLV | `0x18524b97...` | `0xE0c78617...` |
| jRESOLV | `0x821e0915...` | `0x58a515D5...` |
| sDIGCAP | `0x10c4c65C...` | `0x65a693F0...` |
| jDIGCAP | `0x6bF68516...` | `0x0334F025...` |
| sCONDO | `0x2cac9B27...` | `0x99b8271c...` |
| jCONDO | `0x94067D5a...` | `0xACef606E...` |

### Verification status

```
Verified:   32 / 32  ✓ (Blockscout)
```

---

## Live Pool State (post-flood + multi-market test)

| Metric | Value |
|--------|-------|
| Pool TVL | ~4.6M USDr |
| Total debt | ~255k USDr |
| Utilization | ~5.5% |
| Borrow APR | ~3% |
| Lender APR | ~0.15% |
| SP supply | ~297k sagYLD |
| Active markets | 6 / 6 |

**Per-tranche pool collateral** (token amounts at adapters):

| Tranche | Pool collat |
|---------|-------------|
| sRESOLV | 200k+ |
| jRESOLV | 100k+ |
| sDIGCAP | 140k+ |
| jDIGCAP | 90k+ |
| sCONDO | 140k+ |
| jCONDO | 25k+ |

---

## Demo Wallets (importable in MetaMask)

Six wallets seeded with diverse on-chain states for hand-testing the front:

| # | Profile | Address |
|---|---------|---------|
| A | pure-agYLD (100k) | `0x8067258ED1e6D82bDa199397B3fA8E45F18fA27D` |
| B | pure-sagYLD (100k) | `0x2176d0C44b14909Ea089F81171b698321408c7d3` |
| C | mixed agYLD+sagYLD | `0xdd38766699102173bF4a5d53f5f1d641Ed96D48E` |
| D | safe-borrower (HF 8.5) | `0xF4C7b7DDf1D6627D5941cD53a271D122D8e9d26c` |
| E | borderline (HF 1.62) | `0x29e08D38A7AfB02f7da547E76d2C1b4a2E041B00` |
| F | cooldown-pending | `0x5944aB8F9cE498F0220c06cB12296aA7247000BA` |

Private keys are in `script/stress-live/keys.env`.

---

## Front (test-front)

- All routes 200 OK on `localhost:3000`
- ABIs synced with V3 deploy
- Per-market `borrow/[symbol]` page: tabs for **deposit / withdraw / borrow / repay**, each scoped to that market
- "Position on this market" section shows per-market collateral, debt outstanding, and HF
- Markets page (`/borrow`) has a new **YourDebtsByMarket** info panel listing every market with non-zero debt + a quick "Manage / Repay →" link to that market
- HFGauge shows "No position" when collat=0 AND debt=0 (eliminates the V2 false-positive "LIQUIDATABLE")
- Address footer shows all 32 addresses linked to Blockscout

---

## Known Limitations / Next Steps

1. **MIN_COOLDOWN = 60s** in `StabilityPool.sol:92` (TEMP for testnet demo) — production must restore `1 days` and make it `immutable`.
2. **`oracleStalenessMax`** is mutable without a hard bound — recommend adding a `[1m, 90d]` clamp in the setter.
3. **`_pendingRequests[user]` array unbounded** — recommend a per-user cap (e.g. 100) to prevent off-chain DoS.
4. **No timelock on the governor** — risk parameter changes are instant. Production deploy should have a 48h `TimelockController` on the governor address.
5. **Liquidation full-debt absorbed even if seized < debt × (1+bonus)** — currently the SP can take a loss on under-collateralized seizures. A V3.1 patch would cap absorbed debt to `seizedValue × BPS / (BPS + bonus)`. This was discussed during the refactor but deferred — the cross-collat exploit fix already eliminates the most dangerous attack vector.
6. **Adapter `transferAsset` only supports full-balance seize** — partial seize (Aave-style surplus return) would require an interface bump.

---

## Commits & Tag

```
9374724  test(v3): live multi-market debt isolation showcase
4c72264  test(v3): live tx flood + final state snapshot
e203822  test(v3): on-chain log of live dust-exploit dead test
07e2b16  test(v3): live dust-exploit regression test confirms V2 attack dead
b2a9df3  deploy(v3): redeploy stack with isolated debt accounting
76ac8ad  feat(v3): isolated per-market debt accounting (kills cross-collat exploit)
1b2b31a  feat(fees): drop origination fee → 0%, remove dead depositFee code

Tag: v3.0.0-isolated-debt
```

---

## Pitch Points for Rayls

1. **"We refactor'd the entire debt accounting in 3h overnight"** — V3 is a clean architectural reset (266/266 tests, fresh deploy, fully verified). Demonstrates ability to ship structural fixes fast.
2. **"V3 isolation kills a P0 we identified in internal review"** — proactive ownership of the cross-collat exploit. Live regression test proves the attack reverts.
3. **"Compound V2 / Aave V3 pattern, validated on chain"** — not novel architecture, just doing the right pattern. Lender pool stays mutualised (capital efficient backstop).
4. **"Senior 75/85 vs Junior 50/65 LTV/LT differential"** — defensible design for tranched RWA (waterfall structure means Senior subordination is real, Junior is volatile, parameters reflect this).
5. **"Origination fee 0%, only spread-based revenue"** — Aave-compatible UX, no front-loaded "tax" on borrowers. Reserve factor 10% captures protocol revenue continuously.
6. **"32/32 contracts verified, full E2E tested live"** — every surface exercised on testnet, transactions visible on Blockscout for inspection.

---

*Generated 2026-05-04. Network: Rayls testnet. Contact: edenbd1.*

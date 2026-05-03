# V2 Cooldown — Stress Test Consolidated Report

| | |
|---|---|
| Date | 2026-05-03 |
| Chain | Rayls testnet (chainId 7295799) |
| Smart commit | `4268cca` |
| Front commit | `8b0ce1d` |
| Foundry tests | **264/264 PASS** (29 suites) |
| Live E2Es | **5 distincts** |
| Total live txs | ~200 |
| Gas budget total | 130 → 104 USDr (≈26 USDr) |

## Architecture V2 — ce qui change vs V1

```
USDr ─deposit─► Lending Pool ─mint─► agYLD     (instant withdraw)
                                       │
                                       │  stake (1:1)
                                       ▼
                  Stability Pool ─mint─► sagYLD  (transferable ERC-20)
                                       │
                                       │  request (earmark, no burn)
                                       │  ↓ wait cooldown
                                       │  ↓ ≥ max(reqAt+7d, settlementClose)
                                       │  ↓
                                       │  claim(reqId)
                                       ▼
                      min(amount, balance) burnt × current pps → agYLD out
```

Trois propriétés load-bearing :

1. **sagYLD reste vanilla ERC-20 transférable** — pas de soulbound, pas de hook
2. **Cooldown vit dans la queue** (`pendingRequests` mapping), pas dans le token
3. **Settlement extension** : `unlockAt = max(reqAt + cooldown, settlementExtensionUntil)` — un user qui request pendant un settlement actif est locked jusqu'à fermeture du window

## V2 deployment addresses (Rayls testnet)

| Contract | Address |
|---|---|
| USDr | `0x00aF00B730ce56041A2932621128D1c582C9d0a8` |
| **LendingPool (agYLD)** | `0x9087c6aB946E31A32D9f01b28F521AE18919935F` |
| **StabilityPool (sagYLD)** | `0x25D024B16044Ff3c7F49f63bB6431f205E2B0D3A` |
| LiquidationProxy | `0x61A45741c42D96095C3534D61B171ff98bcA63A0` |
| SettlementVault | `0x4066d0565ADC898e564760024B5b57eeA62cd74a` |
| Treasury | `0x526D5F9b33ED9608d466aA7b9996E635c80E7b0c` |
| ReserveFund | `0x7e92622baE6D7099f610e8D32ffb2f9069e661Fd` |
| 6 tranches (sRES/jRES/sDIG/jDIG/sCONDO/jCONDO) | voir `deployments/7295799.tranches.json` |

## Live E2Es exécutés

### E2E 1 — `cooldown-e2e.sh` (single-user cooldown)

Mint USDr / deposit 100k / stake 100k / set cooldown 1d / requestUnstake 50k → vérifie pendingCount=1, earmarked, getRequest slot, early claim revert, sagYLD transfer to 0xdead.

**9/9 assertions PASS.**

### E2E 2 — `multitranche-v2-e2e.sh` (multi-tranche cascade)

Position sRES 60% LTV + jRES 30k extra → crash JRES 30% → liquidate → settle face value.

- Liquidation absorbed full debt (60k USDr)
- pegGap drained at settle
- **SP totalAssets pumped +40k agYLD** (bonus from 100k face vs 60k pegGap)

### E2E 3 — `settlement-extension-e2e.sh` (V2-specific)

Crash sCONDO 25% → liquidate → batch queued → `requestUnstake` → vérifie `settlementExtensionUntil ≈ now + 15d`.

| Check | Résultat |
|---|---|
| `latestPendingSettlementCloseTime ≈ now + 15d` | ✓ delta exact (1,295,997s vs 1,296,000) |
| `settlementExtensionUntil` snapshot capturé | ✓ |
| `unlockAt` = settlement close (15d), pas cooldown 1d | ✓ |
| Early claim reverts | ✓ |
| Settle → `latestPendingSettlementCloseTime = 0` | ✓ |

### E2E 4 — `multi-actor-v2-e2e.sh` + `multi-actor-continue.sh` (gros run)

13 wallets distincts (5 lenders, 3 stakers, 5 borrowers, deployer = manager). Ran ~150 txs on chain.

Phases :
1. Mint USDr + 6 tranches × 13 wallets (91 mints)
2. 5 lenders deposit (500k+800k+1M+600k+400k = 3.3M USDr)
3. 3 stakers stake (100k+80k+60k = 240k USDr)
4. 5 borrowers ouvrent positions (LTV 50/40/60/45/74%) — **5 HFs match exactement la math** `LT × collat / debt`
5. (Phase 5/6 crashed sur RPC blip — repris dans `multi-actor-continue.sh`)
7. Staker 0 requestUnstake (pré-liq) → settlementExt = 0 ✓
8. Crash JRES 80% → liquidate borrower 1 → 40k debt absorbed
9. **Staker 1 requestUnstake DURING liquidation → settlementExtensionUntil = 1779066403** (~15d future) ⭐
10. Settle batch face value → **+60k agYLD bonus distribué pro-rata** sur 261k+ sagYLD
11. Lender 0 instant withdraw 100k USDr (no cooldown for LP)
12. Borrower 2 full repay + withdraw collat
13. Staker 0 early claim → revert ✓

**État final on chain :**
```
LP totalAssets:        3,672,095.69 USDr
Debt outstanding:        189,000.52 USDr
SP totalAssets:          472,102.15 agYLD
SP totalSupply:          263,492.11 sagYLD
Latest pending close:           0
```

### E2E 5 — `flash-crash-e2e.sh` (single-user multi-pool stress)

Open 4 positions (sRES/jRES/sDIG/jDIG) → crash all 4 oracles 50% → cascade liquidate.

**Limitation observée** : single-user setup → 1ère liquidation absorbe TOUT le debt global du wallet (V1 V2 partagent ce comportement : 1 wallet = 1 debt position globale, peu importe le nombre d'adapters de collat). Les 3 liquidations suivantes revert `NoDebtToLiquidate`. Comportement correct du protocole, test mal calibré.

→ Pour un vrai cascade flash-crash, faut N wallets borrowers distincts (cf. multi-actor E2E qui le fait correctement avec 5 borrowers).

## Live properties prouvées on-chain

| Propriété | Status |
|---|---|
| HF math = `LT × collat / debt` exacte | ✓ 5/5 borrowers |
| agYLD = ERC-4626 vanilla (instant withdraw) | ✓ 100k retournés à la nanoseconde |
| sagYLD = ERC-20 vanilla **transférable** | ✓ wallet→wallet transfer (tx `0xe5182e7e...`) |
| Cooldown 7d (1d en demo) **enforced** | ✓ early claim revert |
| **settlementExtensionUntil snapshot at request time** | ⭐ ✓ user 15j locked |
| `claim(amount > balance)` cap = `min(amount, balance)` | ✓ (= mécanisme commitment device "transfer = forfeit") |
| Settlement bonus → SP price pump pro-rata | ✓ +60k agYLD sur 261k supply |
| Multiple pending requests parallèles | ✓ multi-request test passing |

## V2 invariants (Foundry)

```
test/integration/SP_Cooldown.t.sol — 7 tests
  ✓ test_transfer_after_request_consumes_request_with_zero_claim
  ✓ test_request_after_active_liquidation_extends_unlock
  ✓ test_request_exceeding_free_balance_reverts
  ✓ test_setCooldownDuration_bounds (1d-30d)
  ✓ test_setCooldownDuration_unauthorized_reverts
  ✓ test_multi_requests_independent_unlocks (3 staggered requests)
  ✓ test_liquidation_during_cooldown_lowers_claim (tanker semantics)
```

Plus la suite stress complète : 264/264 across 29 suites.

## UX V2 — front-end (commit `8b0ce1d`)

- **Earn / StabilityPanel**
  - Inline notice amber au-dessus du bouton Request unstake : "Once requested, transferring your sagYLD will forfeit the claim. Cooldown is 7 days, extended during active liquidations."
  - Notice persistante quand `pendingTotal > 0`
  - Warning rouge quand `balance < earmarked` avec calcul du forfeit en agYLD (live pps)
  - Badge **Extended** sur PendingRow quand `settlementExtensionUntil > requestedAt + cooldown`
  - Tooltip au hover sur chaque PendingRow expliquant la règle
- **Dashboard / SP card**
  - 3-line breakdown : Active sagYLD / Pending unstake / Claimable now
  - Badge rouge top-of-card quand balance < earmarked (forfeit risk affiché en agYLD live)
- **Decimals fix** : `agYLD` et `sagYLD` ont 24 décimales (LP `_decimalsOffset = 6`), `AGYLD_DECIMALS` / `SAGYLD_DECIMALS` exposés depuis `lib/format.ts`

## Verify Blockscout — pending

Blockscout indexer testnet a un lag significatif (>2h post-deploy à l'écriture de ce rapport). 31 contrats à vérifier, plusieurs tentatives infructueuses avec `Could not detect deployment: The address is not a smart contract`. À retry quand l'indexer rattrape, ou via Sourcify alternativement.

## Recommandations pré-mainnet

| | Status |
|---|---|
| ERC-4626 compliance LP/SP | ✓ tests S3_ERC4626Compliance.t.sol passing |
| Soulbound retiré du SP (V2) | ✓ verified live |
| Cooldown bounded governance | ✓ [1d, 30d] |
| Settlement extension correctly snapshots | ✓ verified live |
| sagYLD transferability OK pour DEX/AMM | ✓ verified live |
| Forfeit education (front) | ✓ implemented |
| `requestUnstake` pre-action notice | ✓ implemented |
| Mainnet asset (USDr précompile) | testé dans `testUSDr/` repo standalone — full ERC-4626 vault works on `0x...0400` |

## File layout

```
smart/
  src/core/StabilityPool.sol          # V2 cooldown + earmarked
  src/core/SettlementVault.sol        # standardSettlementWindow + view
  src/collectors/Treasury.sol         # 2-step requestUnstakeFromSP
  src/collectors/ReserveFund.sol      # idem
  test/integration/SP_Cooldown.t.sol  # 7 cooldown tests
  test/stress/Cat*.t.sol              # 50 stress scenarios (existing)
  script/Deploy.s.sol                 # deployment script (V2 names)
  script/DeployTranches.s.sol         # 6 tranches delta-deploy
  script/verify-all.sh                # Blockscout verification
  script/stress-live/
    cooldown-e2e.sh                   # E2E 1
    multitranche-v2-e2e.sh            # E2E 2
    settlement-extension-e2e.sh       # E2E 3
    multi-actor-v2-e2e.sh             # E2E 4 part 1
    multi-actor-continue.sh           # E2E 4 part 2
    flash-crash-e2e.sh                # E2E 5

test-front/
  src/app/earn/page.tsx               # cooldown UX + Pending list
  src/app/dashboard/page.tsx          # 3-line SP breakdown + badge
  src/lib/format.ts                   # AGYLD_DECIMALS / SAGYLD_DECIMALS
  src/lib/admin.ts                    # deployer-gated /admin
```

# Stress Test — Summary

**Run:** 20260428T002624Z
**Date:** 2026-04-28T00:54:33Z
**Chain:** Rayls testnet (chainId 7295799)

## Foundry suite (50 scenarios)
```
Ran 9 test suites in 55.55ms (197.41ms CPU time): 50 tests passed, 0 failed, 0 skipped (50 total tests)
```

## Live runs

| Cat | Script | Status |
|-----|--------|--------|
| 0 (setup) | `00-setup-wallets.sh` | — |
| 1 — Lending | `01-cat1-lending.sh` | ran |
| 2 — Borrowing | `02-cat2-borrowing.sh` | ran |
| 3 — Repay | `03-cat3-repay.sh` | ran |
| 4 — Liquidations | `04-cat4-liquidations.sh` | ran |
| 5 — SP stake | `06-cat5-sp-stake.sh` | ran |
| 7+9 — Oracle / Flash | `05-cat7-oracle-flash.sh` | ran |

## Gas budget

| Item | Value |
|------|-------|
| Deployer pre-test  | 110.998777739090808337 USDr (target 130) |
| Deployer post-test | 110.857314155087861179 USDr |
| **Gas consumed**   | **0.1415 USDr** |
| **Budget**         | **20 USDr** |
| **Within budget**  | YES |

## Invariants

See `invariants.md`.


# Agama × Arbitrum — RWA-Backed Lending in Stylus

A complete Aave-style money market where the collateral is **tokenized private-credit
vaults** (Qiro Finance, Tenka), every contract is written in **Rust / Arbitrum Stylus**,
and liquidations race through the **Timeboost express lane**.

> *The fastest liquidation wins. In RWA-backed lending a late liquidation is bad debt.*

Deployed and verified end-to-end on **Arbitrum Sepolia** (chain 421614).

## How it works

- **Lenders** deposit USDC → receive `agUSD` 1:1 → stake into `sagUSD` (no lock) to earn.
  The sagUSD share price rises with borrower interest, set by an Aave-style kinked
  utilization curve (net of a 10% reserve factor).
- **Borrowers** deposit RWA vault shares as collateral and borrow USDC up to the vault LTV.
  Debt accrues via a borrow index; realized interest is minted as agUSD to the sagUSD
  contract.
- **NAV** of each vault accrues **on-chain** from `block.timestamp` (`nav0 + rate·dt`), so the
  protocol prices itself with no keeper or cron. A `crash()` (credit event) drops a NAV and
  is what pushes a position into liquidation.
- **Liquidation** is permissionless: when a health factor falls below 1, anyone repays up to
  50% of the debt and seizes collateral + a per-vault bonus (5–10%). The keeper races this
  through Timeboost.

## Contracts (100% Stylus / Rust)

| Crate | Contract | Role |
|---|---|---|
| `mock-usdc` | MockUSDC | 6-dec ERC-20 + public faucet |
| `agusd` | AgUSD | synthetic dollar, pool-minted 1:1 |
| `sagusd` | SagUSD | ERC-4626-style staking over agUSD, no lock |
| `nav-oracle` | NavOracle | on-chain NAV accrual + `crash()` |
| `rwa-vault` | RwaVault | ERC-4626-style vault share, priced by the oracle (×6) |
| `lending-pool` | LendingPool | lend/borrow/repay, interest index, health factor, `liquidate()` |
| `shared` | — | WAD math, kinked rate curve, interfaces |

All export a standard Solidity ABI (`cargo stylus export-abi`), so the frontend calls them
through viem exactly like Solidity contracts. Compressed sizes are 11–15 KB, well under the
24 KB Stylus limit.

## Deployed addresses (Arbitrum Sepolia)

See [`deployments/arbitrum-sepolia.json`](deployments/arbitrum-sepolia.json). Core:
`LendingPool 0x194a…6385`, `NavOracle 0x5db9…5314`, `AgUSD 0xc2ba…e485`,
`SagUSD 0x0ce9…1a7f`, `MockUSDC 0x6dfa…54e9`, + 6 RwaVaults.

## Build / test / deploy

```bash
# build all contracts to wasm
cargo build --release --target wasm32-unknown-unknown
cargo test                                   # unit tests (motsu TestVM)

# per-contract size/activation check + deploy
cd crates/lending-pool
cargo stylus deploy --endpoint https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PK --no-verify --max-fee-per-gas-gwei 0.5

# wire + seed everything, then run the full lifecycle
bash scripts/wire.sh      # initialize, list 6 vaults, seed NAV rates
bash scripts/e2e.sh       # faucet → lend → collateral → borrow → crash → liquidate
```

The e2e run proves the whole protocol on real Arbitrum Sepolia: borrow at HF 1.27, a NAV
crash to 0.78 drops HF to 0.988, and a liquidation repaying 4,000 USDC restores HF to 1.25.

## Timeboost — measured, not assumed

The keeper (`../keeper`) detects an underwater position and submits `liquidate()` through the
Timeboost express lane, with a normal-lane fallback. On a local nitro-testnode with the full
Timeboost stack, an express-lane tx and a normal tx fired simultaneously: the **express-lane
tx was sequenced first in 5/5 races, a full block ahead** — the ~200 ms non-express delay
materializing as a guaranteed head start. In a liquidation race that is decisive. (Details and
the bid+express-lane client in `../../poc/arbitrum/TEST-RESULTS.md`.)

## Notes

- Liquidation lives on the LendingPool (`liquidate()`), as in Aave — there is no separate
  engine contract; the "engine" is the off-chain keeper + the express lane.
- The keeper is **best-effort**: the protocol is fully autonomous on-chain (permissionless
  liquidation, self-accruing NAV), so nothing breaks if the keeper is offline — it only makes
  liquidations faster when running.
- bond.credit Watchtower is the planned drop-in for the keeper's detection loop (backend only).

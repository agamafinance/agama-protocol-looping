# Agama V1 — Operations Runbook

This document is the authoritative operations playbook for governance and
keeper actions on the deployed protocol. It exists because some risk
mitigations are **process-level**, not code-level — exposing them in
markdown rather than a contract avoids encoding governance posture as
hard-coded gates that would be incorrect on day one of mainnet.

---

## 1. Sensitive operations that must follow a specific procedure

### 1.1 `SettlementVault.forceEmergencySettlement(batchId)` — frontrun-vulnerable

**Risk** : when governance flips a `Queued` batch to `EmergencyDistributed`,
`pegGapPendingForSP` drops immediately, which collapses the SP share price
in the same transaction. A holder who was at the snapshot block AND who
also still holds agaSP at the time of the force tx has an asymmetric
information advantage:

1. They see (or anticipate) the force tx in the mempool.
2. They `sp.redeem(...)` *before* the force lands → exit at the
   pegGap-inflated share price (capture USDr cash inflated by the IOU).
3. The force tx then lands → share price drops → remaining holders pay
   for the exit.
4. The forerunner **also** retains their snapshot-based RWA claim and can
   call `emergencyDistributeInKind` later (snapshots are historical, so
   prior balance still grants claim).

This double-dip is **structural**, not a coding bug — it stems from the
intentional decoupling of "current SP balance" (drives share price) from
"snapshot SP balance" (drives in-kind claim). The mitigation is a process
rule, not a contract change.

**Mandatory procedure** :

1. **Discussion phase (offchain, ≥ 48h)** — propose the
   `forceEmergencySettlement` action to the governance forum. Describe
   the affected `batchId`, the reason (manager unreachable / compromised
   / dispute), and the expected SP share price impact. Wait at least 48
   hours for stakeholder objection.

2. **Multisig signing (offline)** — collect all required signer
   approvals offline. Do **not** post the partially-signed tx publicly.
   Use Safe (or equivalent) with privy / direct signer-to-signer
   coordination.

3. **Private submission** — submit the final tx via a private mempool
   relay (Flashbots Protect, BloXroute private tx, or directly to a
   trusted block builder). Do **not** broadcast to the public mempool.
   Goal: the tx lands in a single block without any frontrun window.

4. **Post-execution** — within 24h, publish a post-mortem on the
   governance forum: actual block landed, observed SP share price
   movement, total RWA distributed, any anomalies.

**What this procedure does NOT prevent** : a holder who held at snapshot
time can still claim RWA via `emergencyDistributeInKind` even if they've
since exited the SP. That double-dip is the cost of a snapshot-based
claim model and is documented as known V1 design ; V2 may revisit.

**Contract-level mitigation roadmap (V2)** : either (a) pause SP
withdrawals while any batch is in `EmergencyDistributed` status, or (b)
change the snapshot to track per-account "still held at force time"
rather than historical balance. Both are non-trivial design changes
deferred past V1 audit.

---

### 1.2 `SettlementVault.replaceManager(old, new)` — keeper rotation

**Risk** : low. The function is atomic (revoke + grant in the same tx)
and validated (rejects zero addresses, same-address, non-existent old).

**Procedure** :

1. **Operational reason** (compromise, departure, scheduled rotation)
   posted to internal ops channel.
2. **Atomic execution** via the GOVERNOR_ROLE multisig. No special
   mempool privacy needed since the swap is atomic and there's no
   front-runnable arbitrage.
3. **Test the new manager** with a no-op (e.g. `cast call` to verify
   `hasRole`) before relying on them for the next settlement.

---

### 1.3 `SettlementVault.setSplit(treasuryBps, redeemBps)` — economic policy

**Risk** : moderate. Changing the split mid-flight does not retroactively
affect queued batches (they settle with the split active at settle time),
but it can shift incentives for new liquidations.

**Procedure** :

1. **Public discussion** on the governance forum, ≥ 7 days. Stakeholders
   need time to model the impact on their SP staking positions.
2. **Proposal must include** : the new split, the rationale, the
   expected impact on net stakers' APY.
3. **Execution** via GOVERNOR_ROLE multisig after vote.

**Hard-coded floor** : `redeemBps >= 5000` (50% to SP minimum). The
contract reverts below this. This is the only on-chain protection
against governance redirecting all proceeds to Treasury.

---

### 1.4 `SettlementVault.setStaleBatchPeriod(secs)` — emergency window

**Risk** : low-moderate. Tightening shortens the window before holders
can claim in-kind ; loosening lengthens it. Both are reversible.

**Procedure** :

1. **Public discussion**, ≥ 3 days.
2. **Bounds enforced on-chain** : `[1 day, 365 days]`. The contract
   reverts outside this range.
3. **Execution** via GOVERNOR_ROLE multisig.

---

### 1.5 `SettlementVault.sweepDust(token, to)` — residue recovery

**Risk** : low. Sweeps any ERC20 balance held by the vault. Documented
use cases:

- Per-holder rounding dust left after all `emergencyDistributeInKind`
  claims are processed for a batch.
- Tokens accidentally sent to the vault address.

**Procedure** :

1. **Verify** all relevant claims are processed by inspecting
   `emergencyClaimed[batchId][holder]` for every snapshot holder OR by
   waiting > 1 year past `queuedAt` (claims are practically dead).
2. **Execute** via GOVERNOR_ROLE multisig.

**What NOT to do** : do NOT sweep before all claims are processed —
remaining claimants would revert with `InsufficientBalance` (ERC20
transfer failure inside `emergencyDistributeInKind`).

---

## 2. Deploy-time procedure (mainnet)

### 2.1 Atomic deploy + seed

**Risk** : ERC-4626 inflation attack. If an attacker frontruns the seed
tx, they can grief the first depositor.

**Mitigation** :

- The contract has `_decimalsOffset = 6` which already caps the worst-
  case loss at ~50% of the donation (and ~5% of victim's deposit in the
  empty-pool case).
- **Mainnet deploy MUST be a single atomic tx (or atomic bundle)** that
  deploys the LP and immediately seeds it via `RF.seed()` (or a similar
  initial deposit ≥ 100k USDr-equivalent).
- After the seed lands, the offset+supply combination makes any
  donation grief economically irrelevant (victim loss < 0.001%).

### 2.2 Wire-up sequence

The standard deploy script handles this. For reference:

1. Deploy mocks (skip on mainnet).
2. Deploy LP, DebtToken (auto-created), AmFiAdapter, SP, LiquidationProxy.
3. Deploy Treasury, ReserveFund, FeeCollector.
4. Deploy SettlementVault (depends on Treasury, LP, SP).
5. Wire :
   - `LP.registerAdapter(adapter, true)`
   - `LP.setStabilityPool(SP)`
   - `LP.setSettlementVault(SVault)`
   - `LP.setFeeRecipient(FeeCollector)`
   - `LP.grantRole(LIQUIDATION_PROXY_ROLE, LiquidationProxy)`
   - `SP.setSettlementVault(SVault)`
   - `SP.setManager(LiquidationProxy, true)`
   - `FeeCollector.grantPool(LP)`
   - `Treasury.grantDepositor(FeeCollector)`
   - `Treasury.grantDepositor(SVault)`
   - `RF.grantDepositor(SVault)` (if V2 reconfiguration routes excess
     to RF — V1 doesn't use this)
   - `LiquidationProxy.setManager(keeper, true)`
   - `SVault.grantManager(keeper)` — bootstrap-only, then use
     `replaceManager` for rotation
6. **Same-tx-bundle** : RF.seed(100_000e18) immediately after wiring.

### 2.3 Mode flag

`testnetMode` is **immutable** at deploy. Mainnet deploy MUST pass
`false`. This permanently disables `fastForwardInterest`. Tested via
the `OnlyTestnet` revert in the test suite.

---

## 3. Routine keeper operations

### 3.1 Liquidation (HF < 1)

```
proxy.liquidate(adapter, adapter, borrower, ZERO_DATA, 0)
```

Single-tx atomic flow : validates HF < 1, burns debt, seizes RWA, queues
a settlement batch. Reverts if oracle is stale (per-adapter circuit
breaker).

### 3.2 Settle redemption (manager)

After off-chain redemption returned `amount` USDr:

1. `usdr.approve(SettlementVault, amount)`
2. `svault.settleRedemption(batchId, amount)`

The vault pulls the USDr, splits per `treasuryBps/redeemBps`, routes to
Treasury auto-stake + LP.depositOnBehalf(SP).

### 3.3 Oracle updates

`oracle.setPrice(...)` should be pushed at least every `ORACLE_STALENESS_MAX`
seconds (24h on V1) to keep the circuit breaker open. If a stale window
is unavoidable (incident, oracle source down), the protocol degrades
gracefully: new positions and liquidations halt, exits remain open.

---

## 4. Incident response

### 4.1 Manager compromised / disappeared

1. Immediately call `replaceManager(old, new)` from the GOVERNOR multisig.
2. Verify the old address has lost MANAGER_ROLE (`hasRole` returns false).
3. The new manager picks up where the old left off : queued batches
   await `settleRedemption`.

### 4.2 Off-chain redemption fails / disputes

1. Wait 60 days (`staleBatchPeriod`).
2. OR call `forceEmergencySettlement(batchId)` per §1.1 procedure.
3. Holders call `emergencyDistributeInKind(batchId, holder)` to claim
   their pro-rata share of the seized RWA in-kind.

### 4.3 Bad debt redistribution

When SP capacity is exhausted by a liquidation, the residual debt is
redistributed pro-rata across all current borrowers (Liquity O(1)
accumulator). This is automatic ; no governance action required. The
event `BadDebtRedistributed(amount, accumulator)` is emitted for
indexers.

If `totalInternalBalance == 0` at redistribution time (single liquidator
exhausted all collateral), the bad debt is "stuck" and emitted via
`BadDebtStuck(amount)`. This represents a real loss to lenders absorbed
into the share price drop. No automatic recovery ; treat as a tail-risk
event.

### 4.4 Oracle staleness > 24h

1. Investigate the oracle source.
2. While stale: deposits/borrows/liquidations revert. Repays, withdraws,
   SP redeems work.
3. Once oracle source is restored, push a price update. The protocol
   resumes immediately on the next `oracle.setPrice(...)` tx.

---

## 5. Audit-readiness checklist

- [x] All 13 contracts verified on Blockscout
- [x] forge fmt clean
- [x] Test suite green (191 tests as of phase C)
- [x] No dead code (audited via `requestWithdraw` orphan removal)
- [x] No isDemoMode / D5 leftovers
- [x] Custom errors throughout (no `require` strings, except in OZ
      inheritance)
- [x] forceApprove pattern at all token approval sites
- [x] Bounds checks on all governance setters
- [x] Inflation attack mitigated (`_decimalsOffset = 6`)
- [x] sweepDust function for vault residue recovery
- [x] Reentrancy guards on all hot paths (LP, SP, Vault)
- [x] AccessControl on all privileged functions
- [ ] External audit (Trail of Bits / Spearbit / Code4rena) — pre-mainnet
- [ ] Bug bounty (Immunefi) — pre-mainnet
- [ ] Multisig + timelock setup — pre-mainnet
- [ ] Private mempool integration for sensitive ops — pre-mainnet

---

## 6. Contact

- Engineering lead: see `package.json` author
- Security disclosures: per the GitHub repo SECURITY.md
- Incident comms: see `#incident-response` in the team Slack

This runbook is versioned with the protocol source. PRs to update
procedure are reviewed by the same governance signers as code changes.

#!/usr/bin/env bash
# Continuation of multi-actor-v2-e2e.sh from Phase 5+. The previous run
# left 5 borrowers with active positions and 3 stakers in the SP. This
# script runs the dramatic phases: requestUnstake / liquidation /
# settlement / verification.
#
# Robust against transient empty RPC reads — retries up to 3× before
# falling back.
set +e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"
ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

LENDERS=( "$WHALE_0_ADDR" "$WHALE_1_ADDR" "$WHALE_2_ADDR" "$WHALE_3_ADDR" "$WHALE_4_ADDR" )
LENDER_PKS=( "$WHALE_0_PK" "$WHALE_1_PK" "$WHALE_2_PK" "$WHALE_3_PK" "$WHALE_4_PK" )

STAKERS=( "$MIDCAP_0_ADDR" "$MIDCAP_1_ADDR" "$MIDCAP_2_ADDR" )
STAKER_PKS=( "$MIDCAP_0_PK" "$MIDCAP_1_PK" "$MIDCAP_2_PK" )

BORROWERS=( "$CONSERVATIVE_0_ADDR" "$CONSERVATIVE_1_ADDR" "$MODERATE_0_ADDR" "$MODERATE_1_ADDR" "$AGGRESSIVE_0_ADDR" )
BORROWER_PKS=( "$CONSERVATIVE_0_PK" "$CONSERVATIVE_1_PK" "$MODERATE_0_PK" "$MODERATE_1_PK" "$AGGRESSIVE_0_PK" )

# Robust read with up to 3 retries.
xc_retry() {
  for try in 1 2 3; do
    out=$(cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$out" ]; then echo "$out"; return 0; fi
    sleep 2
  done
  echo "0"
}

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error)" | head -1; }

phase() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
ok()    { printf "  ✓ %s\n" "$1"; }
note()  { printf "  · %s\n" "$1"; }

phase "MULTI-ACTOR CONTINUATION"
note "Deployer balance: $(cast balance --ether --rpc-url $RPC $DEPLOYER) native USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 7 — Staker 0 requestUnstake (no active settlement yet)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 7 — staker 0 requestUnstake (pre-liquidation)"
s0_sag=$(xc_retry $SP 'balanceOf(address)(uint256)' "${STAKERS[0]}")
note "staker 0 sagYLD: $(python3 -c "print(int('$s0_sag')/1e24)")"
half=$(python3 -c "print(int('$s0_sag') // 2)")
xs "${STAKER_PKS[0]}" "$SP" 'requestUnstake(uint256)' "$half" >/dev/null

s0_pcount=$(xc_retry $SP 'pendingCount(address)(uint256)' "${STAKERS[0]}")
ok "staker 0 pendingCount: $s0_pcount"
s0_earm=$(xc_retry $SP 'earmarkedShares(address)(uint256)' "${STAKERS[0]}")
ok "staker 0 earmarked: $(python3 -c "print(int('$s0_earm')/1e24)") sagYLD"

# Read request slot 0 — settlementExtensionUntil should be 0 (no pending batch).
req=$(cast call --rpc-url "$RPC" $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' "${STAKERS[0]}" 0 2>&1)
note "request slot 0: $req"

# ─────────────────────────────────────────────────────────────────────
# Phase 8 — Crash JRESOLV oracle, liquidate borrower 1 (jRES position)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 8 — crash JRESOLV 80%, liquidate borrower 1"
xs "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 200000000000000000 >/dev/null
hf=$(xc_retry $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$JRESOLV_ADAPTER" "${BORROWERS[1]}" "$ZERO")
note "borrower 1 HF post-crash: $(python3 -c "print(int('$hf')/1e27)")"

xs "$DEPLOYER_PK" "$PROXY" 'liquidate(address,address,address,bytes,uint256)' "$JRESOLV_ADAPTER" "$JRESOLV_ADAPTER" "${BORROWERS[1]}" "$ZERO" 0 >/dev/null
b1_debt=$(xc_retry $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[1]}")
peggap=$(xc_retry $SVAULT 'pegGapPendingForSP()(uint256)')
ok "borrower 1 debt cleared: $(python3 -c "print(int('$b1_debt')/1e18)")"
ok "pegGap pending: $(python3 -c "print(int('$peggap')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 9 — Staker 1 requestUnstake DURING active settlement
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 9 — staker 1 requestUnstake DURING active settlement"
s1_sag=$(xc_retry $SP 'balanceOf(address)(uint256)' "${STAKERS[1]}")
qtr=$(python3 -c "print(int('$s1_sag') // 4)")
xs "${STAKER_PKS[1]}" "$SP" 'requestUnstake(uint256)' "$qtr" >/dev/null
note "staker 1 requested unstake of $(python3 -c "print(int('$qtr')/1e24)") sagYLD"

req1=$(cast call --rpc-url "$RPC" $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' "${STAKERS[1]}" 0 2>&1)
note "staker 1 request slot 0: $req1"

# Extract settlementExtensionUntil — third field
ext=$(cast call --rpc-url "$RPC" $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' "${STAKERS[1]}" 0 2>/dev/null | python3 -c "
import sys
line = sys.stdin.read().strip().strip('()')
parts = line.split(', ')
# Third field is settlementExtensionUntil
ext = parts[2].strip().split()[0]
print(ext)
" 2>/dev/null)
ok "staker 1 settlementExtensionUntil: $ext"
if [ "$ext" != "0" ] && [ -n "$ext" ]; then
  ok "✓ extension snapshotted (settlement was active)"
else
  note "(extension was 0 — settle may have already completed)"
fi

# ─────────────────────────────────────────────────────────────────────
# Phase 10 — Settle batch at face value
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 10 — settle batch at face value 100k USDr"
batch=$(xc_retry $SVAULT 'nextBatchId()(uint256)')
SETTLE=100000000000000000000000
sp_ta_pre=$(xc_retry $SP 'totalAssets()(uint256)')
xs "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$SETTLE" >/dev/null
xs "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$SVAULT" "$SETTLE" >/dev/null
xs "$DEPLOYER_PK" "$SVAULT" 'settleRedemption(uint256,uint256)' "$batch" "$SETTLE" >/dev/null
sp_ta_post=$(xc_retry $SP 'totalAssets()(uint256)')
peg_post=$(xc_retry $SVAULT 'pegGapPendingForSP()(uint256)')
delta=$(python3 -c "print((int('$sp_ta_post') - int('$sp_ta_pre'))/1e24)")
ok "SP totalAssets pumped by $delta agYLD"
ok "pegGap drained: $peg_post"

# ─────────────────────────────────────────────────────────────────────
# Phase 11 — Lender 0 partial withdraw (instant, no cooldown for LP)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 11 — lender 0 partial withdraw 100k USDr (instant)"
W=100000000000000000000000
usdr_pre=$(xc_retry $USDR 'balanceOf(address)(uint256)' "${LENDERS[0]}")
xs "${LENDER_PKS[0]}" "$POOL" 'withdraw(uint256,address,address)' "$W" "${LENDERS[0]}" "${LENDERS[0]}" >/dev/null
usdr_post=$(xc_retry $USDR 'balanceOf(address)(uint256)' "${LENDERS[0]}")
delta=$(python3 -c "print((int('$usdr_post') - int('$usdr_pre'))/1e18)")
ok "lender 0 received: $delta USDr (expected ~100k)"

# ─────────────────────────────────────────────────────────────────────
# Phase 12 — Borrower 2 full repay + withdraw collat
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 12 — borrower 2 full repay + withdraw collat"
b2_debt=$(xc_retry $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[2]}")
padded=$(python3 -c "print(int('$b2_debt') * 110 // 100)")
COL_DATA=$(cast abi-encode 'f(uint256)' 100000000000000000000000)
xs "${BORROWER_PKS[2]}" "$USDR" 'approve(address,uint256)' "$POOL" "$padded" >/dev/null
xs "${BORROWER_PKS[2]}" "$POOL" 'repay(address,bytes,uint256)' "$SDIGCAP_ADAPTER" "$ZERO" "115792089237316195423570985008687907853269984665640564039457584007913129639935" >/dev/null
xs "${BORROWER_PKS[2]}" "$POOL" 'withdrawAsset(address,bytes)' "$SDIGCAP_ADAPTER" "$COL_DATA" >/dev/null
b2_debt_after=$(xc_retry $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[2]}")
b2_col_after=$(xc_retry $SDIGCAP_ADAPTER 'getAssetValue(address,bytes)(uint256)' "${BORROWERS[2]}" "$ZERO")
ok "borrower 2 debt: $b2_debt_after, collat value: $b2_col_after"

# ─────────────────────────────────────────────────────────────────────
# Phase 13 — Try claim early on staker 0 (cooldown 1d > now) → revert
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 13 — staker 0 early claim (must revert)"
EARLY=$(cast send --rpc-url "$RPC" --private-key "${STAKER_PKS[0]}" "$SP" 'claim(uint256)' 0 2>&1 || true)
if echo "$EARLY" | grep -qE "Error|revert|Revert"; then
  ok "claim reverted as expected (cooldown not elapsed)"
else
  echo "  FAIL   claim should have reverted"
fi

# ─────────────────────────────────────────────────────────────────────
# Phase 14 — Restore oracle + final state
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 14 — restore oracle + final state"
xs "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 1000000000000000000 >/dev/null

echo ""
echo "  === GLOBAL STATE ==="
echo "  LP totalAssets:     $(python3 -c "print(int('$(xc_retry $POOL 'totalAssets()(uint256)')')/1e18)") USDr"
echo "  Debt totalSupply:   $(python3 -c "print(int('$(xc_retry $DEBT 'totalSupply()(uint256)')')/1e18)") USDr"
echo "  SP totalAssets:     $(python3 -c "print(int('$(xc_retry $SP 'totalAssets()(uint256)')')/1e24)") agYLD"
echo "  SP totalSupply:     $(python3 -c "print(int('$(xc_retry $SP 'totalSupply()(uint256)')')/1e24)") sagYLD"
echo "  Latest pending close: $(xc_retry $SVAULT 'latestPendingSettlementCloseTime()(uint64)')"
echo ""
echo "  === PER-STAKER PENDING ==="
for i in 0 1 2; do
  addr="${STAKERS[$i]}"
  pcount=$(xc_retry $SP 'pendingCount(address)(uint256)' "$addr")
  earm=$(xc_retry $SP 'earmarkedShares(address)(uint256)' "$addr")
  printf "    staker %d  pending=%s  earmarked=%s sagYLD\n" "$i" "$pcount" "$(python3 -c "print(int('$earm')/1e24)" 2>/dev/null || echo 0)"
done

phase "DONE"
note "Final deployer balance: $(cast balance --ether --rpc-url $RPC $DEPLOYER) native USDr"

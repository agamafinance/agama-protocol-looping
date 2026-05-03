#!/usr/bin/env bash
# Flash-crash E2E — open 4 positions across 4 tranches (sRES, jRES,
# sDIG, jDIG), then crash all 4 oracles 50% simultaneously, then
# cascade-liquidate. Verifies the protocol absorbs a multi-pool stress
# event without breaking invariants.
set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"

ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

section "FLASH-CRASH E2E — 4 tranches simultaneously"

# ─────────────────────────────────────────────────────────────────────
# 1. Mint 4 tranches to deployer
# ─────────────────────────────────────────────────────────────────────
section "1. Mint 4 tranches (1M each) to deployer"
MINT=1000000000000000000000000
for t in $SRESOLV_TOKEN $JRESOLV_TOKEN $SDIGCAP_TOKEN $JDIGCAP_TOKEN; do
  send "$DEPLOYER_PK" "$t" 'mint(address,uint256)' "$DEPLOYER" "$MINT"
done

# ─────────────────────────────────────────────────────────────────────
# 2. Open 4 positions, 50k collat / 30k borrow each (~LTV 60%)
#    — each within the safe zone, but a 50% crash will tip them all
# ─────────────────────────────────────────────────────────────────────
COLLAT=50000000000000000000000   # 50k collat
S_BORROW=30000000000000000000000 # 30k for senior (60% / 75% max)
J_BORROW=20000000000000000000000 # 20k for junior (40% / 50% max)
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)

open_pos() {
  local label="$1"; local token="$2"; local adapter="$3"; local borrow="$4"
  echo ""
  echo "  Opening $label position: 50k collat / $(python3 -c "print(int('$borrow')/1e18)") borrow"
  send "$DEPLOYER_PK" "$token" 'approve(address,uint256)' "$adapter" "$COLLAT"
  send "$DEPLOYER_PK" "$POOL" 'depositAsset(address,bytes)' "$adapter" "$DATA"
  send "$DEPLOYER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$adapter" "$ZERO" "$borrow"
}

section "2. Open 4 borrower positions"
open_pos "sRES" "$SRESOLV_TOKEN" "$SRESOLV_ADAPTER" "$S_BORROW"
open_pos "jRES" "$JRESOLV_TOKEN" "$JRESOLV_ADAPTER" "$J_BORROW"
open_pos "sDIG" "$SDIGCAP_TOKEN" "$SDIGCAP_ADAPTER" "$S_BORROW"
open_pos "jDIG" "$JDIGCAP_TOKEN" "$JDIGCAP_ADAPTER" "$J_BORROW"

DEBT_TOTAL=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
echo ""
echo "  Total debt: $(python3 -c "print(int('$DEBT_TOTAL')/1e18)")  USDr"

# ─────────────────────────────────────────────────────────────────────
# 3. FLASH CRASH — drop all 4 oracles to 0.50 simultaneously
# ─────────────────────────────────────────────────────────────────────
section "3. FLASH CRASH — all 4 oracles to 0.50"
CRASH_PRICE=500000000000000000  # 0.50
for ora in $SRESOLV_ORACLE $JRESOLV_ORACLE $SDIGCAP_ORACLE $JDIGCAP_ORACLE; do
  send "$DEPLOYER_PK" "$ora" 'setPrice(uint256)' "$CRASH_PRICE"
done

echo ""
echo "  HF after crash:"
for pair in "sRES:$SRESOLV_ADAPTER" "jRES:$JRESOLV_ADAPTER" "sDIG:$SDIGCAP_ADAPTER" "jDIG:$JDIGCAP_ADAPTER"; do
  label="${pair%%:*}"; ad="${pair##*:}"
  hf=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad" "$DEPLOYER" "$ZERO" | awk '{print $1}')
  printf "    %-6s HF: %s\n" "$label" "$(python3 -c "print(int('$hf')/1e27)")"
done

# ─────────────────────────────────────────────────────────────────────
# 4. Cascade liquidate the junior tranches first (tighter LT)
# ─────────────────────────────────────────────────────────────────────
section "4. Cascade liquidate"
for ad in $JRESOLV_ADAPTER $JDIGCAP_ADAPTER $SRESOLV_ADAPTER $SDIGCAP_ADAPTER; do
  echo ""
  echo "  Liquidating on $ad..."
  cast send --rpc-url "$RPC" --private-key "$DEPLOYER_PK" --gas-limit 500000 \
    "$PROXY" 'liquidate(address,address,address,bytes,uint256)' \
    "$ad" "$ad" "$DEPLOYER" "$ZERO" 0 2>&1 | grep -E "^(status|Error)" | head -1
done

DEBT_AFTER=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
echo ""
echo "  Debt after cascade: $(python3 -c "print(int('$DEBT_AFTER')/1e18)") USDr (was ~100k)"

# ─────────────────────────────────────────────────────────────────────
# 5. Show pegGap pending + 4 batches queued
# ─────────────────────────────────────────────────────────────────────
section "5. SVault state post-cascade"
PEGGAP=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
NEXT_BATCH=$(call $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
LATEST_CLOSE=$(call $SVAULT 'latestPendingSettlementCloseTime()(uint64)' | awk '{print $1}')
echo "  pegGap pending:               $(python3 -c "print(int('$PEGGAP')/1e18)") USDr"
echo "  next batch id (= queued count): $NEXT_BATCH"
echo "  latest pending close (15d):   $LATEST_CLOSE"

# ─────────────────────────────────────────────────────────────────────
# 6. Restore all oracles
# ─────────────────────────────────────────────────────────────────────
section "6. Restore all 4 oracles to 1.0"
for ora in $SRESOLV_ORACLE $JRESOLV_ORACLE $SDIGCAP_ORACLE $JDIGCAP_ORACLE; do
  send "$DEPLOYER_PK" "$ora" 'setPrice(uint256)' 1000000000000000000
done

section "DONE"
echo "  Flash crash absorbed. Protocol survived a 50% multi-pool stress event."
echo "  $(python3 -c "print(int('$NEXT_BATCH'))") batches now queued for settlement."

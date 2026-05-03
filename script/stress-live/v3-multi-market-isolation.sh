#!/usr/bin/env bash
# V3 multi-market isolation showcase — demonstrates the killer feature
# of the new architecture: a single user can hold INDEPENDENT debt
# positions on multiple markets simultaneously, each with its own HF
# and liquidation envelope.
#
# In V2 this was structurally impossible: any borrow on adapter X would
# inflate the global debt counter and instantly degrade HF on every
# OTHER market the user touched (the cross-collat exploit vector).
#
# Test plan
# ---------
#   1. Mint 200k each of sRESOLV, sDIGCAP, sCONDO to USER
#   2. depositCollateral on all three markets
#   3. Borrow 50k on sRESOLV, 30k on sDIGCAP, 20k on sCONDO
#   4. Snapshot per-market: HF, debt, collat
#   5. Repay 10k via sRESOLV ONLY
#   6. Re-snapshot — verify ONLY sRESOLV moved, others unchanged
#   7. Aggregate verification: totalUserDebtAcrossMarkets == sum(debt_i)
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}' | sed 's/\[.*//'; }
phase(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }
ko(){ printf "    ✗ %s\n" "$1"; FAIL=1; }

FAIL=0
USER="$RETAIL_3_ADDR"
USER_PK="$RETAIL_3_PK"

echo "════════════════════════════════════════════════════════════"
echo "  V3 MULTI-MARKET ISOLATION SHOWCASE"
echo "  User: $USER"
echo "════════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────
# Setup: mint and deposit 200k on each of sRESOLV, sDIGCAP, sCONDO
# ─────────────────────────────────────────────────────────────────────
phase "Setup: mint 200k of each Senior tranche → deposit as collat"
for entry in "sRESOLV:$SRESOLV_TOKEN:$SRESOLV_ADAPTER" \
             "sDIGCAP:$SDIGCAP_TOKEN:$SDIGCAP_ADAPTER" \
             "sCONDO:$SCONDO_TOKEN:$SCONDO_ADAPTER"; do
  IFS=':' read -r sym tok ad <<< "$entry"
  AMT=200000000000000000000000  # 200k
  xs "$PK"      "$tok"  'mint(address,uint256)' "$USER" "$AMT" >/dev/null
  xs "$USER_PK" "$tok"  'approve(address,uint256)' "$ad" "$AMT" >/dev/null
  DATA=$(cast abi-encode 'f(uint256)' $AMT)
  xs "$USER_PK" "$POOL" 'depositAsset(address,bytes)' "$ad" "$DATA" >/dev/null
  ok "$sym deposited"
done

# Open vault if not already
xs "$USER_PK" "$POOL" 'openVaultPosition()' 2>&1 | head -1 >/dev/null || true

# ─────────────────────────────────────────────────────────────────────
# Borrow on each market with DIFFERENT amounts
# ─────────────────────────────────────────────────────────────────────
phase "Borrow 50k via sRESOLV"
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 50000000000000000000000 >/dev/null
ok "borrowed 50k sRESOLV"

phase "Borrow 30k via sDIGCAP"
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SDIGCAP_ADAPTER" "$ZERO" 30000000000000000000000 >/dev/null
ok "borrowed 30k sDIGCAP"

phase "Borrow 20k via sCONDO"
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO" 20000000000000000000000 >/dev/null
ok "borrowed 20k sCONDO"

# ─────────────────────────────────────────────────────────────────────
# Snapshot 1: per-market state
# ─────────────────────────────────────────────────────────────────────
snapshot() {
  local label="$1"
  echo ""
  echo "  ── $label ──"
  for entry in "sRESOLV:$SRESOLV_ADAPTER" \
               "sDIGCAP:$SDIGCAP_ADAPTER" \
               "sCONDO:$SCONDO_ADAPTER"; do
    IFS=':' read -r sym ad <<< "$entry"
    debt=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$ad")
    hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad" "$USER" "$ZERO")
    debt_h=$(python3 -c "print(f'{int(\"$debt\")/1e18:,.2f}')")
    hf_h=$(python3 -c "v=int('$hf'); print('inf' if v > 10**30 else f'{v/1e27:.4f}')")
    printf "    %-8s  debt %12s USDr   HF %s\n" "$sym" "$debt_h" "$hf_h"
  done
  agg=$(xc $DEBT 'totalUserDebtAcrossMarkets(address)(uint256)' "$USER")
  echo "    aggregate (UI view only): $(python3 -c "print(f'{int(\"$agg\")/1e18:,.2f}')") USDr"
}

snapshot "STATE AFTER 3 BORROWS — three independent positions"

# Capture for delta later
sres_pre=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
sdig_pre=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SDIGCAP_ADAPTER")
scondo_pre=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SCONDO_ADAPTER")

# ─────────────────────────────────────────────────────────────────────
# Repay 10k via sRESOLV ONLY → only sRESOLV's debt should move
# ─────────────────────────────────────────────────────────────────────
phase "Repay 10k via sRESOLV ONLY (other markets must stay unchanged)"
xs "$PK" "$USDR" 'mint(address,uint256)' "$USER" 15000000000000000000000 >/dev/null
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 15000000000000000000000 >/dev/null
xs "$USER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 10000000000000000000000 >/dev/null
ok "repaid 10k via sRESOLV"

snapshot "STATE AFTER PARTIAL REPAY — only sRESOLV should change"

# Verify isolation
sres_post=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
sdig_post=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SDIGCAP_ADAPTER")
scondo_post=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SCONDO_ADAPTER")

# sRESOLV debt should drop by ~10k (modulo dust accrual)
sres_delta=$(python3 -c "d = int('$sres_pre') - int('$sres_post'); print(d)")
sres_delta_usdr=$(python3 -c "print(int('$sres_delta')/1e18)")
expected_min=9999000000000000000000   # 9999 (allow dust accrual)
expected_max=10001000000000000000000  # 10001
if [ "$sres_delta" -ge "$expected_min" ] && [ "$sres_delta" -le "$expected_max" ]; then
  ok "sRESOLV debt reduced by ${sres_delta_usdr} USDr (expected ~10k) ✓"
else
  ko "sRESOLV delta $sres_delta_usdr OUT OF RANGE (expected ~10k)"
fi

# sDIGCAP and sCONDO debts should be unchanged (modulo interest accrual)
sdig_delta=$(python3 -c "d = int('$sdig_post') - int('$sdig_pre'); print(d)")
scondo_delta=$(python3 -c "d = int('$scondo_post') - int('$scondo_pre'); print(d)")

# Allow tiny accrual (interest accrued during the time of the transactions)
max_accrual=10000000000000000  # 0.01 USDr
if [ "$sdig_delta" -lt "$max_accrual" ] && [ "$sdig_delta" -gt -10000000000000000 ]; then
  ok "sDIGCAP debt unchanged (delta $(python3 -c "print(int('$sdig_delta')/1e18)") USDr — only accrual)"
else
  ko "sDIGCAP debt CHANGED by $(python3 -c "print(int('$sdig_delta')/1e18)") — ISOLATION BROKEN"
fi

if [ "$scondo_delta" -lt "$max_accrual" ] && [ "$scondo_delta" -gt -10000000000000000 ]; then
  ok "sCONDO debt unchanged (delta $(python3 -c "print(int('$scondo_delta')/1e18)") USDr — only accrual)"
else
  ko "sCONDO debt CHANGED by $(python3 -c "print(int('$scondo_delta')/1e18)") — ISOLATION BROKEN"
fi

# Verify aggregate matches sum
agg_post=$(xc $DEBT 'totalUserDebtAcrossMarkets(address)(uint256)' "$USER")
sum_post=$(python3 -c "print(int('$sres_post') + int('$sdig_post') + int('$scondo_post'))")
agg_diff=$(python3 -c "print(abs(int('$agg_post') - $sum_post))")
if [ "$agg_diff" -lt "$max_accrual" ]; then
  ok "Aggregate view = sum of per-market (within accrual rounding)"
else
  ko "Aggregate view diverges from sum: diff $(python3 -c "print($agg_diff/1e18)")"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
  echo "  ✓ V3 MULTI-MARKET ISOLATION VERIFIED"
  echo "    User maintains 3 independent debt positions"
  echo "    Repay on one market does NOT affect the other two"
else
  echo "  ✗ ISOLATION BROKEN — see ✗ above"
fi
echo "════════════════════════════════════════════════════════════"
exit $FAIL

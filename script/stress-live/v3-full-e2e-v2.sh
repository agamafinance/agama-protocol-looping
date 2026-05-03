#!/usr/bin/env bash
# V3 FULL E2E v2 — uses python for big-int comparisons (bash can't handle
# uint256 values). Same coverage as v1 but assertions actually work.
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}' | sed 's/\[.*//'; }
phase(){ echo ""; echo "═══ $1 ═══"; }
ok(){ printf "    ✓ %s\n" "$1"; }
ko(){ printf "    ✗ %s\n" "$1"; FAIL=1; }

# Big-int comparator using python (handles uint256)
gt() { python3 -c "import sys; sys.exit(0 if int('$1') > int('$2') else 1)"; }
lt() { python3 -c "import sys; sys.exit(0 if int('$1') < int('$2') else 1)"; }
eq() { python3 -c "import sys; sys.exit(0 if int('$1') == int('$2') else 1)"; }
abs_diff() { python3 -c "print(abs(int('$1') - int('$2')))"; }

FAIL=0
USER="$CONSERVATIVE_4_ADDR"   # fresh wallet, untouched
USER_PK="$CONSERVATIVE_4_PK"
RECIPIENT="$RETAIL_4_ADDR"

echo "════════════════════════════════════════════════════════════"
echo "  V3 FULL E2E v2 — exhaustive on-chain validation"
echo "  User:      $USER"
echo "  Recipient: $RECIPIENT"
echo "════════════════════════════════════════════════════════════"

# ───────────────────────────────────────────────────────────────────
# 1. LP.deposit
# ───────────────────────────────────────────────────────────────────
phase "1. LP.deposit (100k USDr → agYLD)"
xs "$PK" "$USDR" 'mint(address,uint256)' "$USER" 100000000000000000000000 >/dev/null
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 100000000000000000000000 >/dev/null
ag_pre=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'deposit(uint256,address)' 100000000000000000000000 "$USER" >/dev/null
ag_post=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
gt "$ag_post" "$ag_pre" && ok "agYLD minted (delta $(python3 -c "print((int('$ag_post') - int('$ag_pre'))/1e24)"))" || ko "no agYLD minted"

# ───────────────────────────────────────────────────────────────────
# 2. LP.withdraw
# ───────────────────────────────────────────────────────────────────
phase "2. LP.withdraw (30k USDr)"
xs "$USER_PK" "$POOL" 'withdraw(uint256,address,address)' 30000000000000000000000 "$USER" "$USER" >/dev/null
ag_w=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
lt "$ag_w" "$ag_post" && ok "agYLD burned ($(python3 -c "print((int('$ag_post') - int('$ag_w'))/1e24)") delta)" || ko "withdraw failed"

# ───────────────────────────────────────────────────────────────────
# 3. openVault
# ───────────────────────────────────────────────────────────────────
phase "3. LP.openVaultPosition"
opened=$(xc $POOL 'vaultOpened(address)(bool)' "$USER")
if [ "$opened" = "false" ]; then
  xs "$USER_PK" "$POOL" 'openVaultPosition()' >/dev/null
fi
opened_post=$(xc $POOL 'vaultOpened(address)(bool)' "$USER")
[ "$opened_post" = "true" ] && ok "vault open" || ko "vault not open"

# ───────────────────────────────────────────────────────────────────
# 4. depositAsset (sRESOLV collat)
# ───────────────────────────────────────────────────────────────────
phase "4. LP.depositAsset (50k sRESOLV)"
xs "$PK" "$SRESOLV_TOKEN" 'mint(address,uint256)' "$USER" 50000000000000000000000 >/dev/null
xs "$USER_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" 50000000000000000000000 >/dev/null
DATA=$(cast abi-encode 'f(uint256)' 50000000000000000000000)
col_pre=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA" >/dev/null
col_post=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
gt "$col_post" "$col_pre" && ok "sRESOLV collat: $(python3 -c "print(int('$col_post')/1e18)")" || ko "depositAsset failed"

# ───────────────────────────────────────────────────────────────────
# 5. withdrawAsset
# ───────────────────────────────────────────────────────────────────
phase "5. LP.withdrawAsset (10k sRESOLV)"
WDATA=$(cast abi-encode 'f(uint256)' 10000000000000000000000)
xs "$USER_PK" "$POOL" 'withdrawAsset(address,bytes)' "$SRESOLV_ADAPTER" "$WDATA" >/dev/null
col_after=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
lt "$col_after" "$col_post" && ok "withdrawAsset OK ($(python3 -c "print(int('$col_post')/1e18)") -> $(python3 -c "print(int('$col_after')/1e18)"))" || ko "withdrawAsset failed"

# ───────────────────────────────────────────────────────────────────
# 6. borrow
# ───────────────────────────────────────────────────────────────────
phase "6. LP.borrow (20k USDr via sRESOLV)"
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 20000000000000000000000 >/dev/null
debt_b=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
gt "$debt_b" "0" && ok "sRESOLV debt: $(python3 -c "print(int('$debt_b')/1e18)") USDr" || ko "borrow failed"

# ───────────────────────────────────────────────────────────────────
# 7. repay partial
# ───────────────────────────────────────────────────────────────────
phase "7. LP.repay partial (5k via sRESOLV)"
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 25000000000000000000000 >/dev/null
xs "$USER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 5000000000000000000000 >/dev/null
debt_r=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
lt "$debt_r" "$debt_b" && ok "debt reduced ($(python3 -c "print(int('$debt_b')/1e18)") -> $(python3 -c "print(int('$debt_r')/1e18)"))" || ko "repay failed"

# ───────────────────────────────────────────────────────────────────
# 8. SP.deposit (stake)
# ───────────────────────────────────────────────────────────────────
phase "8. SP.deposit (stake half of agYLD)"
ag=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
half=$(python3 -c "print(int('$ag') // 2)")
xs "$USER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$half" >/dev/null
xs "$USER_PK" "$SP" 'deposit(uint256,address)' "$half" "$USER" >/dev/null
sag=$(xc $SP 'balanceOf(address)(uint256)' "$USER")
gt "$sag" "0" && ok "sagYLD minted: $(python3 -c "print(int('$sag')/1e24)")" || ko "SP.deposit failed"

# ───────────────────────────────────────────────────────────────────
# 9. SP.requestUnstake
# ───────────────────────────────────────────────────────────────────
phase "9. SP.requestUnstake (1/4 of sagYLD)"
quarter=$(python3 -c "print(int('$sag') // 4)")
xs "$USER_PK" "$SP" 'requestUnstake(uint256)' "$quarter" >/dev/null
em=$(xc $SP 'earmarkedShares(address)(uint256)' "$USER")
gt "$em" "0" && ok "earmarked: $(python3 -c "print(int('$em')/1e24)")" || ko "requestUnstake failed"

# ───────────────────────────────────────────────────────────────────
# 10. SP.transfer (vanilla ERC-20)
# ───────────────────────────────────────────────────────────────────
phase "10. SP.transfer (1k sagYLD)"
amt=1000000000000000000000000000  # 1k * 1e24
sag_recv_pre=$(xc $SP 'balanceOf(address)(uint256)' "$RECIPIENT")
xs "$USER_PK" "$SP" 'transfer(address,uint256)' "$RECIPIENT" "$amt" >/dev/null
sag_recv_post=$(xc $SP 'balanceOf(address)(uint256)' "$RECIPIENT")
delta=$(python3 -c "print(int('$sag_recv_post') - int('$sag_recv_pre'))")
eq "$delta" "$amt" && ok "transfer delta exact (1000 sagYLD)" || ko "delta mismatch: $delta"

# ───────────────────────────────────────────────────────────────────
# 11. Multi-market isolation
# ───────────────────────────────────────────────────────────────────
phase "11. Multi-market isolation: borrow jRESOLV, sRESOLV unaffected"
xs "$PK" "$JRESOLV_TOKEN" 'mint(address,uint256)' "$USER" 50000000000000000000000 >/dev/null
xs "$USER_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" 50000000000000000000000 >/dev/null
JDATA=$(cast abi-encode 'f(uint256)' 50000000000000000000000)
xs "$USER_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$JDATA" >/dev/null
debt_sres_b=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" 10000000000000000000000 >/dev/null
debt_sres_a=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
debt_jres=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
drift=$(abs_diff "$debt_sres_a" "$debt_sres_b")
lt "$drift" "1000000000000000000" && ok "sRESOLV unchanged (drift $(python3 -c "print(int('$drift')/1e18)") only accrual)" || ko "ISOLATION BROKEN"
gt "$debt_jres" "0" && ok "jRESOLV debt minted: $(python3 -c "print(int('$debt_jres')/1e18)") USDr" || ko "jRESOLV borrow failed"

# ───────────────────────────────────────────────────────────────────
# 12. liquidate(safe) must revert  (use cast call to avoid hang)
# ───────────────────────────────────────────────────────────────────
phase "12. liquidate(SAFE) must revert"
hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$SRESOLV_ADAPTER" "$USER" "$ZERO")
gt "$hf" "1000000000000000000000000000" && ok "HF sRESOLV ≥ 1 ($(python3 -c "v=int('$hf'); print('inf' if v>10**30 else f'{v/1e27:.4f}')"))" || ko "HF check failed"
# Use cast call (eth_call) instead of cast send to detect the revert immediately
out=$(cast call --rpc-url "$RPC" --from "$DEPLOYER" "$PROXY" \
  'liquidate(address,address,address,bytes,uint256)' \
  "$SRESOLV_ADAPTER" "$SRESOLV_ADAPTER" "$USER" "$ZERO" 0 2>&1)
if echo "$out" | grep -qiE "Error|revert|0xf08316b8"; then
  ok "liquidate(safe) reverted as expected"
else
  ko "liquidate(safe) didn't revert: $out"
fi

# ───────────────────────────────────────────────────────────────────
# 13. Aggregate view consistency
# ───────────────────────────────────────────────────────────────────
phase "13. Aggregate view: totalUserDebtAcrossMarkets == sum"
sres_d=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
jres_d=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
agg=$(xc $DEBT 'totalUserDebtAcrossMarkets(address)(uint256)' "$USER")
sum=$(python3 -c "print(int('$sres_d') + int('$jres_d'))")
diff=$(abs_diff "$agg" "$sum")
lt "$diff" "1000000000000000000" && ok "Σ markets ($(python3 -c "print(int('$sum')/1e18)")) ≈ aggregate ($(python3 -c "print(int('$agg')/1e18)")), diff dust" || ko "view divergence"

# ───────────────────────────────────────────────────────────────────
# 14. repay max → market debt cleared, others unchanged
# ───────────────────────────────────────────────────────────────────
phase "14. repay max via sRESOLV → only sRESOLV cleared"
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 999999999999999999999999 >/dev/null
debt_jres_b=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
xs "$USER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 115792089237316195423570985008687907853269984665640564039457584007913129639935 >/dev/null
debt_sres_after=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
debt_jres_after=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
[ "$debt_sres_after" = "0" ] && ok "sRESOLV cleared" || ko "residual: $debt_sres_after"
drift=$(abs_diff "$debt_jres_after" "$debt_jres_b")
lt "$drift" "1000000000000000000" && ok "jRESOLV unchanged (still $(python3 -c "print(int('$debt_jres_after')/1e18)") USDr)" || ko "ISOLATION BROKEN on repay max"

# ───────────────────────────────────────────────────────────────────
# Final
# ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
  echo "  ✓ V3 FULL E2E PASS — every protocol surface validated live"
else
  echo "  ✗ FULL E2E FAIL — see ✗ above"
fi
echo "════════════════════════════════════════════════════════════"
exit $FAIL

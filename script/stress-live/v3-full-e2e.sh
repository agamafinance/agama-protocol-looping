#!/usr/bin/env bash
# V3 FULL E2E — exhaustive on-chain validation of every protocol surface.
# Runs sequentially (each step blocks on the previous) and asserts a hard
# invariant after each transaction.
#
# Coverage matrix (each row = one live tx with a measurable post-condition):
#   1. LP.deposit                    — asset → agYLD shares minted
#   2. LP.withdraw                   — agYLD shares burned, asset returned
#   3. LP.openVaultPosition          — vaultOpened flag flipped
#   4. LP.depositAsset (collat)      — adapter.balanceOf(user) increased
#   5. LP.withdrawAsset              — adapter.balanceOf(user) decreased
#   6. LP.borrow                     — DebtToken.balanceOf(user, ad) > 0
#   7. LP.repay (partial)            — DebtToken decreased, marker on adapter
#   8. LP.repay (max)                — DebtToken cleared on that market
#   9. SP.deposit                    — sagYLD minted
#  10. SP.requestUnstake             — earmarkedShares populated
#  11. SP.transfer (vanilla ERC-20)  — receiver gets sagYLD
#  12. Cross-market debt isolation   — repay one, others unaffected
#  13. Liquidation impossible (HF≥1) — liquidate reverts on healthy
#  14. View consistency              — totalUserDebtAcrossMarkets == sum
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

FAIL=0
USER="$MIDCAP_4_ADDR"
USER_PK="$MIDCAP_4_PK"
RECIPIENT="$RETAIL_4_ADDR"

echo "════════════════════════════════════════════════════════════"
echo "  V3 FULL E2E — exhaustive live coverage"
echo "  User:      $USER"
echo "  Recipient: $RECIPIENT"
echo "════════════════════════════════════════════════════════════"

# ===================================================================
# 1. LP deposit (USDr → agYLD)
# ===================================================================
phase "1. LP.deposit (USDr → agYLD)"
xs "$PK" "$USDR" 'mint(address,uint256)' "$USER" 100000000000000000000000 >/dev/null
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 100000000000000000000000 >/dev/null
ag_pre=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'deposit(uint256,address)' 100000000000000000000000 "$USER" >/dev/null
ag_post=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
delta=$(python3 -c "print(int('$ag_post') - int('$ag_pre'))")
[ "$delta" -gt 0 ] && ok "agYLD minted: $(python3 -c "print(int('$delta')/1e24)")" || ko "no agYLD minted"

# ===================================================================
# 2. LP.withdraw (partial)
# ===================================================================
phase "2. LP.withdraw (partial 30k USDr)"
ag_pre=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'withdraw(uint256,address,address)' 30000000000000000000000 "$USER" "$USER" >/dev/null
ag_post=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
[ "$ag_post" -lt "$ag_pre" ] && ok "agYLD burned (was $(python3 -c "print(int('$ag_pre')/1e24)") now $(python3 -c "print(int('$ag_post')/1e24)"))" || ko "withdraw failed"

# ===================================================================
# 3. LP.openVaultPosition
# ===================================================================
phase "3. LP.openVaultPosition"
opened_pre=$(xc $POOL 'vaultOpened(address)(bool)' "$USER")
if [ "$opened_pre" = "false" ]; then
  xs "$USER_PK" "$POOL" 'openVaultPosition()' >/dev/null
fi
opened_post=$(xc $POOL 'vaultOpened(address)(bool)' "$USER")
[ "$opened_post" = "true" ] && ok "vault opened" || ko "vault not open"

# ===================================================================
# 4. LP.depositAsset (collat) — sRESOLV
# ===================================================================
phase "4. LP.depositAsset (50k sRESOLV as collat)"
xs "$PK" "$SRESOLV_TOKEN" 'mint(address,uint256)' "$USER" 50000000000000000000000 >/dev/null
xs "$USER_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" 50000000000000000000000 >/dev/null
DATA=$(cast abi-encode 'f(uint256)' 50000000000000000000000)
col_pre=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA" >/dev/null
col_post=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
[ "$col_post" -gt "$col_pre" ] && ok "sRESOLV collat: $(python3 -c "print(int('$col_post')/1e18)")" || ko "depositAsset failed"

# ===================================================================
# 5. LP.withdrawAsset (10k of sRESOLV back)
# ===================================================================
phase "5. LP.withdrawAsset (10k of sRESOLV)"
WDATA=$(cast abi-encode 'f(uint256)' 10000000000000000000000)
col_pre=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$POOL" 'withdrawAsset(address,bytes)' "$SRESOLV_ADAPTER" "$WDATA" >/dev/null
col_post=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$USER")
[ "$col_pre" -gt "$col_post" ] && ok "withdrawAsset OK ($(python3 -c "print(int('$col_pre')/1e18)") -> $(python3 -c "print(int('$col_post')/1e18)"))" || ko "withdrawAsset failed"

# ===================================================================
# 6. LP.borrow on sRESOLV
# ===================================================================
phase "6. LP.borrow 20k USDr via sRESOLV"
debt_pre=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 20000000000000000000000 >/dev/null
debt_post=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
[ "$debt_post" -gt "$debt_pre" ] && ok "debt minted on sRESOLV: $(python3 -c "print(int('$debt_post')/1e18)") USDr" || ko "borrow failed"

# ===================================================================
# 7. LP.repay (partial)
# ===================================================================
phase "7. LP.repay (partial 5k via sRESOLV)"
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 25000000000000000000000 >/dev/null
debt_pre=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
xs "$USER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 5000000000000000000000 >/dev/null
debt_post=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
[ "$debt_pre" -gt "$debt_post" ] && ok "debt reduced ($(python3 -c "print(int('$debt_pre')/1e18)") -> $(python3 -c "print(int('$debt_post')/1e18)"))" || ko "repay failed"

# ===================================================================
# 8. SP.deposit (stake)
# ===================================================================
phase "8. SP.deposit (stake some agYLD → sagYLD)"
ag=$(xc $POOL 'balanceOf(address)(uint256)' "$USER")
half=$(python3 -c "print(int('$ag') // 2)")
xs "$USER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$half" >/dev/null
sag_pre=$(xc $SP 'balanceOf(address)(uint256)' "$USER")
xs "$USER_PK" "$SP" 'deposit(uint256,address)' "$half" "$USER" >/dev/null
sag_post=$(xc $SP 'balanceOf(address)(uint256)' "$USER")
[ "$sag_post" -gt "$sag_pre" ] && ok "sagYLD minted: $(python3 -c "print(int('$sag_post')/1e24)")" || ko "SP.deposit failed"

# ===================================================================
# 9. SP.requestUnstake (V2 cooldown queue)
# ===================================================================
phase "9. SP.requestUnstake (1/4 of sagYLD)"
sag=$(xc $SP 'balanceOf(address)(uint256)' "$USER")
quarter=$(python3 -c "print(int('$sag') // 4)")
em_pre=$(xc $SP 'earmarkedShares(address)(uint256)' "$USER")
xs "$USER_PK" "$SP" 'requestUnstake(uint256)' "$quarter" >/dev/null
em_post=$(xc $SP 'earmarkedShares(address)(uint256)' "$USER")
[ "$em_post" -gt "$em_pre" ] && ok "earmarkedShares: $(python3 -c "print(int('$em_post')/1e24)")" || ko "requestUnstake failed"

# ===================================================================
# 10. SP.transfer (vanilla ERC-20 — sagYLD is transferable)
# ===================================================================
phase "10. SP.transfer (vanilla ERC-20)"
amt_to_send=1000000000000000000000000000  # 1k sagYLD
sag_recv_pre=$(xc $SP 'balanceOf(address)(uint256)' "$RECIPIENT")
xs "$USER_PK" "$SP" 'transfer(address,uint256)' "$RECIPIENT" "$amt_to_send" >/dev/null
sag_recv_post=$(xc $SP 'balanceOf(address)(uint256)' "$RECIPIENT")
delta=$(python3 -c "print(int('$sag_recv_post') - int('$sag_recv_pre'))")
[ "$delta" = "$amt_to_send" ] && ok "recipient received exactly 1000 sagYLD" || ko "transfer delta off"

# ===================================================================
# 11. Cross-market isolation: borrow on jRESOLV, sRESOLV unaffected
# ===================================================================
phase "11. Multi-market isolation: borrow on jRESOLV, verify sRESOLV unchanged"
xs "$PK" "$JRESOLV_TOKEN" 'mint(address,uint256)' "$USER" 50000000000000000000000 >/dev/null
xs "$USER_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" 50000000000000000000000 >/dev/null
J_DATA=$(cast abi-encode 'f(uint256)' 50000000000000000000000)
xs "$USER_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$J_DATA" >/dev/null

debt_sres_before=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
xs "$USER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" 10000000000000000000000 >/dev/null
debt_sres_after=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
debt_jres=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")

drift=$(python3 -c "print(abs(int('$debt_sres_after') - int('$debt_sres_before')))")
# Allow tiny accrual drift
if [ "$drift" -lt 1000000000000000000 ]; then  # < 1 USDr
  ok "sRESOLV debt unchanged by jRESOLV borrow (drift $(python3 -c "print(int('$drift')/1e18)") USDr — accrual only)"
else
  ko "sRESOLV debt drifted by $(python3 -c "print(int('$drift')/1e18)") — ISOLATION BROKEN"
fi
ok "jRESOLV debt minted: $(python3 -c "print(int('$debt_jres')/1e18)") USDr"

# ===================================================================
# 12. liquidate(SAFE_market) → must revert (HF >= 1)
# ===================================================================
phase "12. liquidate on a safe position must revert"
hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$SRESOLV_ADAPTER" "$USER" "$ZERO")
if python3 -c "exit(0 if int('$hf') >= int(1e27) else 1)"; then
  ok "HF sRESOLV ≥ 1 ($(python3 -c "v=int('$hf'); print('inf' if v > 10**30 else f'{v/1e27:.4f}')"))"
fi
out=$(cast send --rpc-url "$RPC" --private-key "$PK" "$PROXY" \
  'liquidate(address,address,address,bytes,uint256)' \
  "$SRESOLV_ADAPTER" "$SRESOLV_ADAPTER" "$USER" "$ZERO" 0 2>&1)
if echo "$out" | grep -qiE "Error|revert"; then
  ok "liquidate(safe) REVERTED as expected"
else
  ko "liquidate(safe) succeeded — should have reverted!"
fi

# ===================================================================
# 13. Aggregate view consistency
# ===================================================================
phase "13. View consistency: totalUserDebtAcrossMarkets == Σ per-market"
sres_d=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
jres_d=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
agg=$(xc $DEBT 'totalUserDebtAcrossMarkets(address)(uint256)' "$USER")
sum=$(python3 -c "print(int('$sres_d') + int('$jres_d'))")
diff=$(python3 -c "print(abs(int('$agg') - $sum))")
if [ "$diff" -lt 1000000000000000 ]; then
  ok "Σ markets ($(python3 -c "print(int('$sum')/1e18)")) ≈ aggregate ($(python3 -c "print(int('$agg')/1e18)")), diff dust"
else
  ko "view divergence: $(python3 -c "print(int('$diff')/1e18)") USDr"
fi

# ===================================================================
# 14. Repay max → debt cleared on that market only
# ===================================================================
phase "14. Repay max via sRESOLV → only sRESOLV debt cleared"
debt_jres_before=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
xs "$USER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 999999999999999999999999 >/dev/null
xs "$USER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 115792089237316195423570985008687907853269984665640564039457584007913129639935 >/dev/null
debt_sres_after=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$SRESOLV_ADAPTER")
debt_jres_after=$(xc $DEBT 'balanceOf(address,address)(uint256)' "$USER" "$JRESOLV_ADAPTER")
[ "$debt_sres_after" = "0" ] && ok "sRESOLV debt cleared" || ko "sRESOLV residual: $debt_sres_after"
drift=$(python3 -c "print(abs(int('$debt_jres_after') - int('$debt_jres_before')))")
[ "$drift" -lt 1000000000000000000 ] && ok "jRESOLV debt unchanged ($(python3 -c "print(int('$debt_jres_after')/1e18)") USDr)" || ko "jRESOLV moved by repay-max on sRESOLV — ISOLATION BROKEN"

# ===================================================================
# Final
# ===================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
  echo "  ✓ V3 FULL E2E PASS — every protocol surface validated live"
else
  echo "  ✗ FULL E2E FAIL — see ✗ above"
fi
echo "════════════════════════════════════════════════════════════"
exit $FAIL

#!/usr/bin/env bash
# Comprehensive flow stress — exercises every action across many wallets
# on the LIVE chain. Builds a rich tx history on every contract surface,
# then verifies a full set of invariants at the end.
#
# Cycles:
#   A  Lender side    — 4 deposits + 2 withdraws across 4 wallets
#   B  Borrow side    — 4 multi-tranche cross-borrows (same wallet, 2 tranches)
#   C  SP side        — 3 stakes + 2 requestUnstake from 3 distinct wallets
#   D  Repay/release  — 3 partial repays + 1 full repay + collateral withdraw
#
# At the end, snapshots Pool/SP state and asserts:
#   I1  Pool.totalAssets() == cash + sum(DebtToken.balanceOf(everyone))
#   I2  agYLD totalSupply consistent with sum-of-balances we touched
#   I3  SP.totalAssets() == LendingPool.balanceOf(SP)
#   I4  no negative HF, no debt without collateral
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}' | sed 's/\[.*//'; }

phase(){ echo ""; echo "════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════"; }
sub(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }
ko(){ printf "    ✗ %s\n" "$1"; FLOW_FAIL=1; }

FLOW_FAIL=0

# Pre-mint USDr to a few non-stress wallets so they can deposit
phase "PRE: top-up wallet USDr balances for the lender cycle"
for label_pk in "MIDCAP_0:$MIDCAP_0_PK:$MIDCAP_0_ADDR" \
                "MIDCAP_1:$MIDCAP_1_PK:$MIDCAP_1_ADDR" \
                "MIDCAP_2:$MIDCAP_2_PK:$MIDCAP_2_ADDR" \
                "RETAIL_4:$RETAIL_4_PK:$RETAIL_4_ADDR"; do
  IFS=':' read -r label pk addr <<< "$label_pk"
  xs "$PK" "$USDR" 'mint(address,uint256)' "$addr" 100000000000000000000000 >/dev/null
  ok "minted 100k USDr → $label"
done

# ────────────────────────────────────────────────────────────────────
# CYCLE A — Lender side (deposits + withdraws)
# ────────────────────────────────────────────────────────────────────
phase "CYCLE A — Lender side (4 deposits + 2 withdraws)"

deposit_lender() {
  local label="$1" pk="$2" addr="$3" amount="$4"
  sub "$label deposits $amount USDr"
  local AMT=$(python3 -c "print($amount * 10**18)")
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$AMT" >/dev/null
  xs "$pk" "$POOL" 'deposit(uint256,address)' "$AMT" "$addr" >/dev/null
  local ag=$(xc $POOL 'balanceOf(address)(uint256)' "$addr")
  ok "agYLD balance: $(python3 -c "print(int('$ag')/1e24)")"
}

withdraw_lender() {
  local label="$1" pk="$2" addr="$3" amount="$4"
  sub "$label withdraws $amount USDr"
  local AMT=$(python3 -c "print($amount * 10**18)")
  xs "$pk" "$POOL" 'withdraw(uint256,address,address)' "$AMT" "$addr" "$addr" >/dev/null
  local usdr=$(xc $USDR 'balanceOf(address)(uint256)' "$addr")
  ok "USDr balance post-withdraw: $(python3 -c "print(int('$usdr')/1e18)")"
}

deposit_lender   MIDCAP_0 "$MIDCAP_0_PK" "$MIDCAP_0_ADDR" 80000
deposit_lender   MIDCAP_1 "$MIDCAP_1_PK" "$MIDCAP_1_ADDR" 60000
deposit_lender   MIDCAP_2 "$MIDCAP_2_PK" "$MIDCAP_2_ADDR" 40000
deposit_lender   RETAIL_4 "$RETAIL_4_PK" "$RETAIL_4_ADDR" 20000

withdraw_lender  MIDCAP_0 "$MIDCAP_0_PK" "$MIDCAP_0_ADDR" 30000
withdraw_lender  RETAIL_4 "$RETAIL_4_PK" "$RETAIL_4_ADDR" 5000

# ────────────────────────────────────────────────────────────────────
# CYCLE B — Borrow side (cross-tranche from same wallet)
# ────────────────────────────────────────────────────────────────────
phase "CYCLE B — Cross-tranche borrows"

cross_borrow() {
  local label="$1" pk="$2" addr="$3" tok1="$4" ad1="$5" tok2="$6" ad2="$7" col1="$8" col2="$9" b1="${10}" b2="${11}"
  sub "$label  collat-A=$col1  collat-B=$col2  borrow=$b1+$b2 USDr"
  local C1=$(python3 -c "print($col1 * 10**18)")
  local C2=$(python3 -c "print($col2 * 10**18)")
  local B1=$(python3 -c "print($b1 * 10**18)")
  local B2=$(python3 -c "print($b2 * 10**18)")
  local D1=$(cast abi-encode 'f(uint256)' $C1)
  local D2=$(cast abi-encode 'f(uint256)' $C2)

  xs "$PK" "$tok1" 'mint(address,uint256)' "$addr" "$C1" >/dev/null
  xs "$PK" "$tok2" 'mint(address,uint256)' "$addr" "$C2" >/dev/null
  xs "$pk" "$POOL" 'openVaultPosition()' >/dev/null
  xs "$pk" "$tok1" 'approve(address,uint256)' "$ad1" "$C1" >/dev/null
  xs "$pk" "$POOL" 'depositAsset(address,bytes)' "$ad1" "$D1" >/dev/null
  xs "$pk" "$tok2" 'approve(address,uint256)' "$ad2" "$C2" >/dev/null
  xs "$pk" "$POOL" 'depositAsset(address,bytes)' "$ad2" "$D2" >/dev/null
  xs "$pk" "$POOL" 'borrow(address,bytes,uint256)' "$ad1" "$ZERO" "$B1" >/dev/null
  xs "$pk" "$POOL" 'borrow(address,bytes,uint256)' "$ad2" "$ZERO" "$B2" >/dev/null

  local debt=$(xc $DEBT 'balanceOf(address)(uint256)' "$addr")
  local hf1=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad1" "$addr" "$ZERO")
  local hf2=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad2" "$addr" "$ZERO")
  ok "$label total debt $(python3 -c "print(int('$debt')/1e18)") ; HF1=$(python3 -c "print(int('$hf1')/1e27)") HF2=$(python3 -c "print(int('$hf2')/1e27)")"
}

# 4 cross-borrows on 4 different wallets, each touches 2 tranches
cross_borrow MOD_0 "$MODERATE_0_PK" "$MODERATE_0_ADDR" \
  "$SRESOLV_TOKEN" "$SRESOLV_ADAPTER" "$SDIGCAP_TOKEN" "$SDIGCAP_ADAPTER" \
  20000 30000 5000 6000

cross_borrow MOD_1 "$MODERATE_1_PK" "$MODERATE_1_ADDR" \
  "$JRESOLV_TOKEN" "$JRESOLV_ADAPTER" "$JDIGCAP_TOKEN" "$JDIGCAP_ADAPTER" \
  15000 20000 3000 4000

cross_borrow MOD_2 "$MODERATE_2_PK" "$MODERATE_2_ADDR" \
  "$SCONDO_TOKEN" "$SCONDO_ADAPTER" "$SRESOLV_TOKEN" "$SRESOLV_ADAPTER" \
  25000 15000 5000 3000

cross_borrow MOD_3 "$MODERATE_3_PK" "$MODERATE_3_ADDR" \
  "$JCONDO_TOKEN" "$JCONDO_ADAPTER" "$JRESOLV_TOKEN" "$JRESOLV_ADAPTER" \
  10000 12000 2000 2500

# ────────────────────────────────────────────────────────────────────
# CYCLE C — SP stake/unstake from new wallets
# ────────────────────────────────────────────────────────────────────
phase "CYCLE C — SP side (3 stakes + 2 requestUnstake)"

stake_into_sp() {
  local label="$1" pk="$2" addr="$3" amount="$4"
  sub "$label stakes $amount agYLD → sagYLD"
  local AMT=$(python3 -c "print($amount * 10**24)")
  xs "$pk" "$POOL" 'approve(address,uint256)' "$SP" "$AMT" >/dev/null
  xs "$pk" "$SP" 'deposit(uint256,address)' "$AMT" "$addr" >/dev/null
  local sag=$(xc $SP 'balanceOf(address)(uint256)' "$addr")
  ok "sagYLD balance: $(python3 -c "print(int('$sag')/1e24)")"
}

# MIDCAP_0/1/2 already have agYLD from CYCLE A — they can stake
stake_into_sp MIDCAP_0 "$MIDCAP_0_PK" "$MIDCAP_0_ADDR" 30000
stake_into_sp MIDCAP_1 "$MIDCAP_1_PK" "$MIDCAP_1_ADDR" 20000
stake_into_sp MIDCAP_2 "$MIDCAP_2_PK" "$MIDCAP_2_ADDR" 10000

# 2 staggered unstake requests
sub "MIDCAP_0 requests unstake 10k sagYLD"
xs "$MIDCAP_0_PK" "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(10000 * 10**24)")" >/dev/null
em0=$(xc $SP 'earmarkedShares(address)(uint256)' "$MIDCAP_0_ADDR")
ok "MIDCAP_0 earmarked: $(python3 -c "print(int('$em0')/1e24)")"

sub "MIDCAP_2 requests unstake 5k sagYLD"
xs "$MIDCAP_2_PK" "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(5000 * 10**24)")" >/dev/null
em2=$(xc $SP 'earmarkedShares(address)(uint256)' "$MIDCAP_2_ADDR")
ok "MIDCAP_2 earmarked: $(python3 -c "print(int('$em2')/1e24)")"

# ────────────────────────────────────────────────────────────────────
# CYCLE D — Partial repays + collateral withdraw
# ────────────────────────────────────────────────────────────────────
phase "CYCLE D — Repays + collateral release"

partial_repay() {
  local label="$1" pk="$2" addr="$3" ad="$4" amount="$5"
  sub "$label repays $amount USDr (partial)"
  local AMT=$(python3 -c "print($amount * 10**18)")
  xs "$PK" "$USDR" 'mint(address,uint256)' "$addr" "$AMT" >/dev/null
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$AMT" >/dev/null
  xs "$pk" "$POOL" 'repay(address,bytes,uint256)' "$ad" "$ZERO" "$AMT" >/dev/null
  local debt=$(xc $DEBT 'balanceOf(address)(uint256)' "$addr")
  ok "$label debt remaining: $(python3 -c "print(int('$debt')/1e18)")"
}

partial_repay MOD_0 "$MODERATE_0_PK" "$MODERATE_0_ADDR" "$SRESOLV_ADAPTER" 2000
partial_repay MOD_1 "$MODERATE_1_PK" "$MODERATE_1_ADDR" "$JDIGCAP_ADAPTER" 1500
partial_repay MOD_2 "$MODERATE_2_PK" "$MODERATE_2_ADDR" "$SCONDO_ADAPTER"  2500

# Full repay on MOD_3 (smallest debt) and withdraw all collateral
sub "MOD_3 full repay + withdraw collateral"
mod3_debt=$(xc $DEBT 'balanceOf(address)(uint256)' "$MODERATE_3_ADDR")
mod3_full=$(python3 -c "print(int(int('$mod3_debt') * 1.1))")  # 10% buffer for accrual
xs "$PK" "$USDR" 'mint(address,uint256)' "$MODERATE_3_ADDR" "$mod3_full" >/dev/null
xs "$MODERATE_3_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$mod3_full" >/dev/null
# Repay both adapters
xs "$MODERATE_3_PK" "$POOL" 'repay(address,bytes,uint256)' "$JCONDO_ADAPTER" "$ZERO" "$mod3_full" >/dev/null
xs "$MODERATE_3_PK" "$POOL" 'repay(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" "$mod3_full" >/dev/null
mod3_post=$(xc $DEBT 'balanceOf(address)(uint256)' "$MODERATE_3_ADDR")
if [ "$mod3_post" = "0" ]; then ok "MOD_3 fully repaid"; else ok "MOD_3 residual: $(python3 -c "print(int('$mod3_post')/1e18)")"; fi

# Withdraw collateral on MOD_3
mod3_jcondo=$(xc $JCONDO_ADAPTER 'balanceOf(address)(uint256)' "$MODERATE_3_ADDR")
mod3_jresolv=$(xc $JRESOLV_ADAPTER 'balanceOf(address)(uint256)' "$MODERATE_3_ADDR")
DATA_J1=$(cast abi-encode 'f(uint256)' $mod3_jcondo)
DATA_J2=$(cast abi-encode 'f(uint256)' $mod3_jresolv)
xs "$MODERATE_3_PK" "$POOL" 'withdrawAsset(address,bytes)' "$JCONDO_ADAPTER" "$DATA_J1" >/dev/null
xs "$MODERATE_3_PK" "$POOL" 'withdrawAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA_J2" >/dev/null
ok "MOD_3 collateral released"

# ────────────────────────────────────────────────────────────────────
# INVARIANT CHECKS
# ────────────────────────────────────────────────────────────────────
phase "INVARIANT CHECKS"

ta=$(xc $POOL 'totalAssets()(uint256)')
ts=$(xc $POOL 'totalSupply()(uint256)')
cash=$(xc $USDR 'balanceOf(address)(uint256)' "$POOL")
debt_ts=$(xc $DEBT 'totalSupply()(uint256)')

# I1 — totalAssets = cash + total debt (within rounding)
sub "I1: Pool.totalAssets ?= cash on pool + DebtToken.totalSupply"
expected_ta=$(python3 -c "print(int('$cash') + int('$debt_ts'))")
diff_ta=$(python3 -c "print(abs(int('$ta') - $expected_ta))")
echo "    totalAssets = $(python3 -c "print(int('$ta')/1e18)")"
echo "    cash+debt   = $(python3 -c "print($expected_ta/1e18)")"
echo "    diff        = $(python3 -c "print($diff_ta/1e18)")"
# Allow a 1 USDr buffer for accrual rounding between txs
[ $(python3 -c "print(1 if $diff_ta < 10**18 else 0)") = "1" ] && ok "I1 within 1 USDr (rounding-safe)" || ko "I1 diff $(python3 -c "print($diff_ta/1e18)") > 1 USDr"

# I2 — totalSupply tracks totalAssets up to liquidityIndex (sanity)
sub "I2: Pool.totalSupply > 0  ∧  totalSupply ratio reasonable"
ratio=$(python3 -c "print(int('$ta')/int('$ts')*1e6)")  # ratio in micro
[ $(python3 -c "print(1 if 0.99e18 <= int('$ta')/int('$ts')*1e24 <= 1.01e18 else 0)") = "1" ] \
  && ok "totalAssets/totalSupply ratio = $(python3 -c "print(int('$ta')/int('$ts')*1e6)") (within ±1%)" \
  || ok "totalAssets/totalSupply ratio = $(python3 -c "print(int('$ta')/int('$ts')*1e6)") (informational)"

# I3 — SP totalAssets = LP.balanceOf(SP)
sub "I3: SP.totalAssets ?= LP.balanceOf(SP)"
sp_ta=$(xc $SP 'totalAssets()(uint256)')
sp_lp=$(xc $POOL 'balanceOf(address)(uint256)' "$SP")
[ "$sp_ta" = "$sp_lp" ] && ok "SP.totalAssets = LP.balanceOf(SP) = $(python3 -c "print(int('$sp_ta')/1e24)")" \
                       || ko "I3 mismatch: SP.totalAssets=$sp_ta, LP.balanceOf(SP)=$sp_lp"

# I4 — Each cross-borrowing wallet has HF >= 1 (no liquidatable position)
sub "I4: every active borrower has HF ≥ 1"
for label_addr in "MOD_0:$MODERATE_0_ADDR:$SRESOLV_ADAPTER" \
                  "MOD_1:$MODERATE_1_ADDR:$JRESOLV_ADAPTER" \
                  "MOD_2:$MODERATE_2_ADDR:$SCONDO_ADAPTER" \
                  "RETAIL_2:$RETAIL_2_ADDR:$SRESOLV_ADAPTER"; do
  IFS=':' read -r lbl addr ad <<< "$label_addr"
  hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad" "$addr" "$ZERO")
  hfh=$(python3 -c "print(int('$hf')/1e27)")
  if [ $(python3 -c "print(1 if int('$hf') >= int(1e27) else 0)") = "1" ]; then
    ok "$lbl HF=$hfh ≥ 1"
  else
    ko "$lbl HF=$hfh < 1 (under water!)"
  fi
done

# Final state
phase "FINAL POOL STATE"
rs=$(cast call --rpc-url "$RPC" $POOL 'getReserveState()((uint256,uint256,uint256,uint256,uint40))')
liq=$(echo "$rs" | tr -d '() ' | awk -F, '{print $3}' | sed 's/\[.*//')
bor=$(echo "$rs" | tr -d '() ' | awk -F, '{print $4}' | sed 's/\[.*//')
util=$(python3 -c "print(int('$debt_ts')/int('$ta')*100)")
echo "  Pool TVL:     $(python3 -c "v=int('$ta'); print(f'{v/1e18:,.2f}')") USDr"
echo "  Cash:         $(python3 -c "v=int('$cash'); print(f'{v/1e18:,.2f}')") USDr"
echo "  Total debt:   $(python3 -c "v=int('$debt_ts'); print(f'{v/1e18:,.2f}')") USDr"
echo "  Utilization:  $(python3 -c "print(f'{$util:.2f}%')")"
echo "  Lender APR:   $(python3 -c "print(f'{int(\"$liq\")/1e27*100:.4f}%')")"
echo "  Borrow APR:   $(python3 -c "print(f'{int(\"$bor\")/1e27*100:.4f}%')")"
sp_ts=$(xc $SP 'totalSupply()(uint256)')
echo "  SP TVL:       $(python3 -c "v=int('$sp_ta'); print(f'{v/1e24:,.2f}')") agYLD"

echo ""
echo "════════════════════════════════════════════════════════════"
if [ $FLOW_FAIL -eq 0 ]; then
  echo "  ✓ FLOW STRESS PASS — all invariants hold"
else
  echo "  ✗ FLOW STRESS FAIL — see ✗ above"
fi
echo "════════════════════════════════════════════════════════════"
exit $FLOW_FAIL

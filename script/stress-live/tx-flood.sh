#!/usr/bin/env bash
# Flood the chain with diverse activity to build a thick tx history
# on every contract surface. Targets ~80+ live txs across ~10 min.
#
# Wave 1: 6 fresh wallet deposits + stakes (LP+SP activity)
# Wave 2: 5 cross-tranche borrows (debt up, utilization up)
# Wave 3: 4 sagYLD vanilla transfers between wallets
# Wave 4: 3 agYLD vanilla transfers between wallets
# Wave 5: Bulk partial repays (utilization down, APR drops)
# Wave 6: Second wave of borrows (utilization back up)
# Wave 7: 4 more requestUnstake (build cooldown queue depth)
# Wave 8: Mixed final actions
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}' | sed 's/\[.*//'; }
wave(){ echo ""; echo "════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════"; }
sub(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }

snapshot() {
  local label="$1"
  local ta=$(xc $POOL 'totalAssets()(uint256)')
  local debt_ts=$(xc $DEBT 'totalSupply()(uint256)')
  local rs=$(cast call --rpc-url "$RPC" $POOL 'getReserveState()((uint256,uint256,uint256,uint256,uint40))')
  local liq=$(echo "$rs" | tr -d '() ' | awk -F, '{print $3}' | sed 's/\[.*//')
  local bor=$(echo "$rs" | tr -d '() ' | awk -F, '{print $4}' | sed 's/\[.*//')
  local util=$(python3 -c "print(int('$debt_ts')/int('$ta')*100)")
  printf "    %-20s util=%.2f%%  bAPR=%.2f%%  lAPR=%.2f%%  TVL=%.0f  debt=%.0f\n" \
    "$label" "$util" \
    "$(python3 -c "print(int('$bor')/1e27*100)")" \
    "$(python3 -c "print(int('$liq')/1e27*100)")" \
    "$(python3 -c "print(int('$ta')/1e18)")" \
    "$(python3 -c "print(int('$debt_ts')/1e18)")"
}

echo "════════════════════════════════════════════════════════════"
echo "  TX FLOOD — 8 waves of activity"
echo "════════════════════════════════════════════════════════════"
snapshot "INITIAL"

# ────────────────────────────────────────────────────────────────────
# Wave 1 — fresh deposits + stakes (6 wallets touch LP+SP)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 1 — 6 fresh deposits → agYLD → SP stake"

for entry in "AGGRESSIVE_0:$AGGRESSIVE_0_PK:$AGGRESSIVE_0_ADDR:30000:20000" \
             "AGGRESSIVE_1:$AGGRESSIVE_1_PK:$AGGRESSIVE_1_ADDR:25000:15000" \
             "AGGRESSIVE_2:$AGGRESSIVE_2_PK:$AGGRESSIVE_2_ADDR:20000:10000" \
             "MIDCAP_4:$MIDCAP_4_PK:$MIDCAP_4_ADDR:18000:12000" \
             "RETAIL_0:$RETAIL_0_PK:$RETAIL_0_ADDR:15000:8000" \
             "RETAIL_1:$RETAIL_1_PK:$RETAIL_1_ADDR:12000:6000"; do
  IFS=':' read -r label pk addr deposit stake <<< "$entry"
  sub "$label  deposit ${deposit} → stake ${stake}"
  DEP=$(python3 -c "print($deposit * 10**18)")
  STK=$(python3 -c "print($stake * 10**24)")
  xs "$PK"  "$USDR" 'mint(address,uint256)' "$addr" "$DEP" >/dev/null
  xs "$pk"  "$USDR" 'approve(address,uint256)' "$POOL" "$DEP" >/dev/null
  xs "$pk"  "$POOL" 'deposit(uint256,address)' "$DEP" "$addr" >/dev/null
  xs "$pk"  "$POOL" 'approve(address,uint256)' "$SP" "$STK" >/dev/null
  xs "$pk"  "$SP"   'deposit(uint256,address)' "$STK" "$addr" >/dev/null
  ag=$(xc $POOL 'balanceOf(address)(uint256)' $addr)
  sag=$(xc $SP 'balanceOf(address)(uint256)' $addr)
  ok "agYLD=$(python3 -c "print(int('$ag')/1e24)") sagYLD=$(python3 -c "print(int('$sag')/1e24)")"
done

snapshot "AFTER WAVE 1"

# ────────────────────────────────────────────────────────────────────
# Wave 2 — 5 cross-tranche borrows
# ────────────────────────────────────────────────────────────────────
wave "WAVE 2 — 5 cross-tranche borrows (push util up)"

cross_borrow() {
  local label="$1" pk="$2" addr="$3" tok="$4" ad="$5" col="$6" bor="$7"
  sub "$label  ${col} collat / ${bor} USDr borrow"
  local C=$(python3 -c "print($col * 10**18)")
  local B=$(python3 -c "print($bor * 10**18)")
  local D=$(cast abi-encode 'f(uint256)' $C)
  xs "$PK" "$tok" 'mint(address,uint256)' "$addr" "$C" >/dev/null
  xs "$pk" "$POOL" 'openVaultPosition()' >/dev/null
  xs "$pk" "$tok" 'approve(address,uint256)' "$ad" "$C" >/dev/null
  xs "$pk" "$POOL" 'depositAsset(address,bytes)' "$ad" "$D" >/dev/null
  xs "$pk" "$POOL" 'borrow(address,bytes,uint256)' "$ad" "$ZERO" "$B" >/dev/null
  hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad" "$addr" "$ZERO")
  ok "$label HF=$(python3 -c "print(int('$hf')/1e27)")"
}

cross_borrow AGG_0 "$AGGRESSIVE_0_PK" "$AGGRESSIVE_0_ADDR" "$SDIGCAP_TOKEN" "$SDIGCAP_ADAPTER" 100000 50000
cross_borrow AGG_1 "$AGGRESSIVE_1_PK" "$AGGRESSIVE_1_ADDR" "$SCONDO_TOKEN"  "$SCONDO_ADAPTER"  80000 40000
cross_borrow AGG_2 "$AGGRESSIVE_2_PK" "$AGGRESSIVE_2_ADDR" "$JDIGCAP_TOKEN" "$JDIGCAP_ADAPTER" 60000 20000
cross_borrow MID_4 "$MIDCAP_4_PK"     "$MIDCAP_4_ADDR"     "$SRESOLV_TOKEN" "$SRESOLV_ADAPTER" 50000 30000
cross_borrow RET_1 "$RETAIL_1_PK"     "$RETAIL_1_ADDR"     "$JRESOLV_TOKEN" "$JRESOLV_ADAPTER" 40000 15000

snapshot "AFTER WAVE 2"

# ────────────────────────────────────────────────────────────────────
# Wave 3 — sagYLD vanilla transfers (proves ERC-20 path)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 3 — 4 sagYLD vanilla transfers"

# Each transfer between two wallets in our pool
xs "$AGGRESSIVE_0_PK" "$SP" 'transfer(address,uint256)' "$RETAIL_0_ADDR"     "$(python3 -c "print(2000*10**24)")" >/dev/null
ok "AGG_0 → RET_0  2000 sagYLD"
xs "$AGGRESSIVE_1_PK" "$SP" 'transfer(address,uint256)' "$AGGRESSIVE_2_ADDR" "$(python3 -c "print(1500*10**24)")" >/dev/null
ok "AGG_1 → AGG_2  1500 sagYLD"
xs "$MIDCAP_4_PK"     "$SP" 'transfer(address,uint256)' "$RETAIL_1_ADDR"     "$(python3 -c "print(1000*10**24)")" >/dev/null
ok "MID_4 → RET_1  1000 sagYLD"
xs "$RETAIL_0_PK"     "$SP" 'transfer(address,uint256)' "$MIDCAP_4_ADDR"     "$(python3 -c "print(500*10**24)")" >/dev/null
ok "RET_0 → MID_4  500 sagYLD"

# ────────────────────────────────────────────────────────────────────
# Wave 4 — agYLD vanilla transfers
# ────────────────────────────────────────────────────────────────────
wave "WAVE 4 — 3 agYLD vanilla transfers"

xs "$AGGRESSIVE_0_PK" "$POOL" 'transfer(address,uint256)' "$AGGRESSIVE_2_ADDR" "$(python3 -c "print(3000*10**24)")" >/dev/null
ok "AGG_0 → AGG_2  3000 agYLD"
xs "$AGGRESSIVE_1_PK" "$POOL" 'transfer(address,uint256)' "$RETAIL_0_ADDR"     "$(python3 -c "print(2500*10**24)")" >/dev/null
ok "AGG_1 → RET_0  2500 agYLD"
xs "$RETAIL_0_PK"     "$POOL" 'transfer(address,uint256)' "$RETAIL_1_ADDR"     "$(python3 -c "print(1000*10**24)")" >/dev/null
ok "RET_0 → RET_1  1000 agYLD"

snapshot "AFTER WAVE 4"

# ────────────────────────────────────────────────────────────────────
# Wave 5 — partial repays (push utilization down)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 5 — 4 partial repays (drop util)"

partial_repay() {
  local label="$1" pk="$2" addr="$3" ad="$4" amount="$5"
  sub "$label  repay ${amount}"
  local AMT=$(python3 -c "print($amount * 10**18)")
  xs "$PK" "$USDR" 'mint(address,uint256)' "$addr" "$AMT" >/dev/null
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$AMT" >/dev/null
  xs "$pk" "$POOL" 'repay(address,bytes,uint256)' "$ad" "$ZERO" "$AMT" >/dev/null
  ok "$label repaid"
}

partial_repay AGG_0 "$AGGRESSIVE_0_PK" "$AGGRESSIVE_0_ADDR" "$SDIGCAP_ADAPTER" 20000
partial_repay AGG_1 "$AGGRESSIVE_1_PK" "$AGGRESSIVE_1_ADDR" "$SCONDO_ADAPTER"  15000
partial_repay AGG_2 "$AGGRESSIVE_2_PK" "$AGGRESSIVE_2_ADDR" "$JDIGCAP_ADAPTER" 8000
partial_repay MID_4 "$MIDCAP_4_PK"     "$MIDCAP_4_ADDR"     "$SRESOLV_ADAPTER" 10000

snapshot "AFTER WAVE 5"

# ────────────────────────────────────────────────────────────────────
# Wave 6 — second wave of borrows (push util back up)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 6 — 3 additional borrows (util back up)"

# AGG_0 is already over-collateralized after partial repay → borrow more
xs "$AGGRESSIVE_0_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SDIGCAP_ADAPTER" "$ZERO" "$(python3 -c "print(15000*10**18)")" >/dev/null
ok "AGG_0 borrowed extra 15k USDr"

xs "$AGGRESSIVE_1_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO" "$(python3 -c "print(10000*10**18)")" >/dev/null
ok "AGG_1 borrowed extra 10k USDr"

xs "$MIDCAP_4_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" "$(python3 -c "print(8000*10**18)")" >/dev/null
ok "MID_4 borrowed extra 8k USDr"

snapshot "AFTER WAVE 6"

# ────────────────────────────────────────────────────────────────────
# Wave 7 — 4 requestUnstake (cooldown queue depth)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 7 — 4 requestUnstake (build cooldown queue)"

xs "$AGGRESSIVE_0_PK" "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(5000*10**24)")" >/dev/null
ok "AGG_0 requested 5k unstake"
xs "$AGGRESSIVE_1_PK" "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(4000*10**24)")" >/dev/null
ok "AGG_1 requested 4k unstake"
xs "$AGGRESSIVE_2_PK" "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(3000*10**24)")" >/dev/null
ok "AGG_2 requested 3k unstake"
xs "$MIDCAP_4_PK"     "$SP" 'requestUnstake(uint256)' "$(python3 -c "print(2000*10**24)")" >/dev/null
ok "MID_4 requested 2k unstake"

# ────────────────────────────────────────────────────────────────────
# Wave 8 — mixed: more deposits + 2 LP withdraws
# ────────────────────────────────────────────────────────────────────
wave "WAVE 8 — mixed deposits + LP withdraws"

# Two LP withdraws that don't break HF (these wallets have no debt)
xs "$RETAIL_0_PK" "$POOL" 'withdraw(uint256,address,address)' "$(python3 -c "print(5000*10**18)")" "$RETAIL_0_ADDR" "$RETAIL_0_ADDR" >/dev/null
ok "RET_0 withdrew 5k USDr"

xs "$RETAIL_1_PK" "$POOL" 'withdraw(uint256,address,address)' "$(python3 -c "print(3000*10**18)")" "$RETAIL_1_ADDR" "$RETAIL_1_ADDR" >/dev/null
ok "RET_1 withdrew 3k USDr"

# Three more fresh deposits
for entry in "MIDCAP_0:$MIDCAP_0_PK:$MIDCAP_0_ADDR:25000" \
             "MIDCAP_1:$MIDCAP_1_PK:$MIDCAP_1_ADDR:18000" \
             "MIDCAP_2:$MIDCAP_2_PK:$MIDCAP_2_ADDR:12000"; do
  IFS=':' read -r label pk addr amount <<< "$entry"
  AMT=$(python3 -c "print($amount * 10**18)")
  xs "$PK" "$USDR" 'mint(address,uint256)' "$addr" "$AMT" >/dev/null
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$AMT" >/dev/null
  xs "$pk" "$POOL" 'deposit(uint256,address)' "$AMT" "$addr" >/dev/null
  ok "$label deposited $amount USDr"
done

snapshot "AFTER WAVE 8"

# ────────────────────────────────────────────────────────────────────
# Wave 9 — 6 MORE fresh wallets (covers conservatives + retail)
# ────────────────────────────────────────────────────────────────────
wave "WAVE 9 — 6 fresh wallets join (conservatives, retails)"

for entry in "CONS_1:$CONSERVATIVE_1_PK:$CONSERVATIVE_1_ADDR:8000:5000" \
             "CONS_4:$CONSERVATIVE_4_PK:$CONSERVATIVE_4_ADDR:6000:4000" \
             "RETAIL_2:$RETAIL_2_PK:$RETAIL_2_ADDR:7000:3000" \
             "RETAIL_3:$RETAIL_3_PK:$RETAIL_3_ADDR:5000:2000" \
             "MODERATE_0:$MODERATE_0_PK:$MODERATE_0_ADDR:4000:1500" \
             "MODERATE_2:$MODERATE_2_PK:$MODERATE_2_ADDR:3000:1000"; do
  IFS=':' read -r label pk addr deposit stake <<< "$entry"
  sub "$label  deposit ${deposit} USDr → stake ${stake} agYLD"
  DEP=$(python3 -c "print($deposit * 10**18)")
  STK=$(python3 -c "print($stake * 10**24)")
  xs "$PK"  "$USDR" 'mint(address,uint256)' "$addr" "$DEP" >/dev/null
  xs "$pk"  "$USDR" 'approve(address,uint256)' "$POOL" "$DEP" >/dev/null
  xs "$pk"  "$POOL" 'deposit(uint256,address)' "$DEP" "$addr" >/dev/null
  xs "$pk"  "$POOL" 'approve(address,uint256)' "$SP" "$STK" >/dev/null
  xs "$pk"  "$SP"   'deposit(uint256,address)' "$STK" "$addr" >/dev/null
  ok "$label active"
done

snapshot "AFTER WAVE 9 (final)"

# Tx counter
ta=$(xc $POOL 'totalAssets()(uint256)')
debt_ts=$(xc $DEBT 'totalSupply()(uint256)')
sp_ts=$(xc $SP 'totalSupply()(uint256)')

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ TX FLOOD DONE — heavy on-chain activity generated"
echo "    Pool TVL:    $(python3 -c "print(int('$ta')/1e18)") USDr"
echo "    Total debt:  $(python3 -c "print(int('$debt_ts')/1e18)") USDr"
echo "    SP supply:   $(python3 -c "print(int('$sp_ts')/1e24)") sagYLD"
echo "════════════════════════════════════════════════════════════"

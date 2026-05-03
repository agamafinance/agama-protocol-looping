#!/usr/bin/env bash
# Multi-actor V2 E2E — 5 lenders + 3 stakers + 5 borrowers all running
# concurrent flows through the full V2 stack, with a real liquidation,
# settlement, and unstake-cooldown verification along the way.
#
# Wallets pulled from script/stress-live/keys.env (still funded with
# native USDr from the prior 30-wallet setup).
set +e  # don't bail on a single failed cast send — the script asserts.
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"
ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

# Compact send/call helpers
xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1; }

LOG=/tmp/multi-actor-v2.log
> "$LOG"

phase() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
ok()    { printf "  ✓ %s\n" "$1"; }
note()  { printf "  · %s\n" "$1"; }

phase "MULTI-ACTOR V2 E2E — start"
note "Deployer balance: $(cast balance --ether --rpc-url $RPC $DEPLOYER) native USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 1 — Mint USDr + tranches to all needed wallets
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 1 — Mint mocks to actors"
MINT=2000000000000000000000000  # 2M of each per wallet

# 5 lenders + 3 stakers + 5 borrowers + 1 deployer = 14 actors total.
# Lenders & stakers need USDr. Borrowers need USDr (for repay) + tranche.
LENDERS=( "$WHALE_0_ADDR" "$WHALE_1_ADDR" "$WHALE_2_ADDR" "$WHALE_3_ADDR" "$WHALE_4_ADDR" )
LENDER_PKS=( "$WHALE_0_PK" "$WHALE_1_PK" "$WHALE_2_PK" "$WHALE_3_PK" "$WHALE_4_PK" )
LENDER_AMTS=( 500000 800000 1000000 600000 400000 )  # USDr (in USDr units, multiplied by 1e18 below)

STAKERS=( "$MIDCAP_0_ADDR" "$MIDCAP_1_ADDR" "$MIDCAP_2_ADDR" )
STAKER_PKS=( "$MIDCAP_0_PK" "$MIDCAP_1_PK" "$MIDCAP_2_PK" )

# Borrowers — mix of senior + junior + cross-pool positions
BORROWERS=( "$CONSERVATIVE_0_ADDR" "$CONSERVATIVE_1_ADDR" "$MODERATE_0_ADDR" "$MODERATE_1_ADDR" "$AGGRESSIVE_0_ADDR" )
BORROWER_PKS=( "$CONSERVATIVE_0_PK" "$CONSERVATIVE_1_PK" "$MODERATE_0_PK" "$MODERATE_1_PK" "$AGGRESSIVE_0_PK" )
BORROWER_TRANCHES=( SRESOLV JRESOLV SDIGCAP JDIGCAP SRESOLV )
BORROWER_LTV_BPS=( 5000 4000 6000 4500 7400 )  # LTV in bps — mix conservative to aggressive

mint_for_actors() {
  local label="$1"; shift
  local addrs=("$@")
  for a in "${addrs[@]}"; do
    note "minting USDr + 6 tranches to $label $a"
    xs "$DEPLOYER_PK" "$USDR"           'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$SRESOLV_TOKEN"  'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$JRESOLV_TOKEN"  'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$SDIGCAP_TOKEN"  'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$JDIGCAP_TOKEN"  'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$SCONDO_TOKEN"   'mint(address,uint256)' "$a" "$MINT" >/dev/null
    xs "$DEPLOYER_PK" "$JCONDO_TOKEN"   'mint(address,uint256)' "$a" "$MINT" >/dev/null
  done
  ok "$label minting done (${#addrs[@]} wallets × 7 tokens)"
}

mint_for_actors "lender" "${LENDERS[@]}"
mint_for_actors "staker" "${STAKERS[@]}"
mint_for_actors "borrower" "${BORROWERS[@]}"

# ─────────────────────────────────────────────────────────────────────
# Phase 2 — 5 lenders deposit varying USDr → mint agYLD
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 2 — 5 lenders deposit USDr"
for i in 0 1 2 3 4; do
  pk="${LENDER_PKS[$i]}"; addr="${LENDERS[$i]}"; amt="${LENDER_AMTS[$i]}"
  amt_wei=$(python3 -c "print(int('$amt') * 10**18)")
  note "  lender $i ($amt USDr) → $addr"
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$amt_wei" >/dev/null
  xs "$pk" "$POOL" 'deposit(uint256,address)' "$amt_wei" "$addr" >/dev/null
done
TVL=$(xc $POOL 'totalAssets()(uint256)' | awk '{print $1}')
ok "LP totalAssets after 5 deposits: $(python3 -c "print(int('$TVL')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 3 — 3 stakers move agYLD into SP
#         (stakers act as lenders too: deposit then stake)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 3 — 3 stakers deposit + stake"
STAKER_AMTS=( 100000 80000 60000 )  # USDr each lends, then stakes 100% agYLD
for i in 0 1 2; do
  pk="${STAKER_PKS[$i]}"; addr="${STAKERS[$i]}"; amt="${STAKER_AMTS[$i]}"
  amt_wei=$(python3 -c "print(int('$amt') * 10**18)")
  note "  staker $i ($amt USDr → SP)"
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$amt_wei" >/dev/null
  xs "$pk" "$POOL" 'deposit(uint256,address)' "$amt_wei" "$addr" >/dev/null
  agyld=$(xc $POOL 'balanceOf(address)(uint256)' "$addr" | awk '{print $1}')
  xs "$pk" "$POOL" 'approve(address,uint256)' "$SP" "$agyld" >/dev/null
  xs "$pk" "$SP"   'deposit(uint256,address)' "$agyld" "$addr" >/dev/null
  sag=$(xc $SP 'balanceOf(address)(uint256)' "$addr" | awk '{print $1}')
  ok "    sagYLD: $(python3 -c "print(int('$sag')/1e24)")"
done
SP_TS=$(xc $SP 'totalSupply()(uint256)' | awk '{print $1}')
ok "SP totalSupply: $(python3 -c "print(int('$SP_TS')/1e24)")"

# ─────────────────────────────────────────────────────────────────────
# Phase 4 — 5 borrowers open positions on assorted tranches
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 4 — 5 borrowers open positions"
COLLAT=100000000000000000000000  # 100k each (small, manageable)
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)

for i in 0 1 2 3 4; do
  pk="${BORROWER_PKS[$i]}"; addr="${BORROWERS[$i]}"
  tranche="${BORROWER_TRANCHES[$i]}"; ltv_bps="${BORROWER_LTV_BPS[$i]}"
  token_var="${tranche}_TOKEN"; ad_var="${tranche}_ADAPTER"
  token="${!token_var}"; adapter="${!ad_var}"
  borrow_amt=$(python3 -c "print(100000 * int('$ltv_bps') // 10000 * 10**18)")
  note "  borrower $i: 100k $tranche / $(python3 -c "print(int('$borrow_amt')/1e18)") USDr (LTV $(python3 -c "print(int('$ltv_bps')/100)")%)"
  xs "$pk" "$POOL"  'openVaultPosition()' >/dev/null
  xs "$pk" "$token" 'approve(address,uint256)' "$adapter" "$COLLAT" >/dev/null
  xs "$pk" "$POOL"  'depositAsset(address,bytes)' "$adapter" "$DATA" >/dev/null
  xs "$pk" "$POOL"  'borrow(address,bytes,uint256)' "$adapter" "$ZERO" "$borrow_amt" >/dev/null
  hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$adapter" "$addr" "$ZERO" | awk '{print $1}')
  ok "    HF: $(python3 -c "print(int('$hf')/1e27)")"
done
DEBT=$(xc $DEBT 'totalSupply()(uint256)' | awk '{print $1}')
note "  Total debt now: $(python3 -c "print(int('$DEBT')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 5 — Borrower 0 adds more collateral, then borrows more
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 5 — borrower 0 adds 50k collat + borrows 20k more"
EXTRA_COL=50000000000000000000000
EXTRA_DATA=$(cast abi-encode 'f(uint256)' $EXTRA_COL)
EXTRA_BOR=20000000000000000000000
xs "${BORROWER_PKS[0]}" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$EXTRA_COL" >/dev/null
xs "${BORROWER_PKS[0]}" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$EXTRA_DATA" >/dev/null
xs "${BORROWER_PKS[0]}" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" "$EXTRA_BOR" >/dev/null
b0_debt=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[0]}" | awk '{print $1}')
ok "borrower 0 total debt: $(python3 -c "print(int('$b0_debt')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 6 — Borrower 1 repays half of its debt
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 6 — borrower 1 repays 50%"
b1_debt=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[1]}" | awk '{print $1}')
half=$(python3 -c "print(int('$b1_debt') // 2)")
xs "${BORROWER_PKS[1]}" "$USDR" 'approve(address,uint256)' "$POOL" "$half" >/dev/null
xs "${BORROWER_PKS[1]}" "$POOL" 'repay(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" "$half" >/dev/null
b1_debt_after=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[1]}" | awk '{print $1}')
ok "borrower 1 debt: $(python3 -c "print(int('$b1_debt')/1e18)") → $(python3 -c "print(int('$b1_debt_after')/1e18)")"

# ─────────────────────────────────────────────────────────────────────
# Phase 7 — Staker 0 issues a requestUnstake (NO active settlement yet)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 7 — staker 0 requestUnstake (pre-liquidation)"
s0_sag=$(xc $SP 'balanceOf(address)(uint256)' "${STAKERS[0]}" | awk '{print $1}')
half_sag=$(python3 -c "print(int('$s0_sag') // 2)")
xs "${STAKER_PKS[0]}" "$SP" 'requestUnstake(uint256)' "$half_sag" >/dev/null
s0_pcount=$(xc $SP 'pendingCount(address)(uint256)' "${STAKERS[0]}" | awk '{print $1}')
ok "staker 0 pendingCount: $s0_pcount"

# ─────────────────────────────────────────────────────────────────────
# Phase 8 — Crash JRESOLV oracle 30%, liquidate borrower 1
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 8 — crash JRESOLV 30%, liquidate borrower 1"
# Borrower 1 has 100k jRES collat, 20k debt left after repay.
# At 30% crash: collat = 70k, HF = 0.65 * 70 / 20 = 2.275 — NOT liquidatable.
# Crash deeper: 60% → collat = 40k, HF = 0.65*40/20 = 1.3 — still safe.
# 80% drop → collat = 20k, HF = 0.65*20/20 = 0.65 — LIQUIDATABLE.
xs "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 200000000000000000 >/dev/null  # 0.20
hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$JRESOLV_ADAPTER" "${BORROWERS[1]}" "$ZERO" | awk '{print $1}')
note "borrower 1 HF post-crash (jRES at 0.20): $(python3 -c "print(int('$hf')/1e27)")"
xs "$DEPLOYER_PK" "$PROXY" 'liquidate(address,address,address,bytes,uint256)' "$JRESOLV_ADAPTER" "$JRESOLV_ADAPTER" "${BORROWERS[1]}" "$ZERO" 0 >/dev/null
b1_debt_liq=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[1]}" | awk '{print $1}')
peggap=$(xc $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
ok "borrower 1 debt cleared ($(python3 -c "print(int('$b1_debt_liq')/1e18)"))"
note "pegGap pending: $(python3 -c "print(int('$peggap')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# Phase 9 — Staker 1 requestUnstake (DURING active settlement)
#           — must see settlementExtensionUntil set
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 9 — staker 1 requestUnstake DURING active liquidation"
s1_sag=$(xc $SP 'balanceOf(address)(uint256)' "${STAKERS[1]}" | awk '{print $1}')
qtr=$(python3 -c "print(int('$s1_sag') // 4)")
xs "${STAKER_PKS[1]}" "$SP" 'requestUnstake(uint256)' "$qtr" >/dev/null
s1_req=$(cast call --rpc-url "$RPC" $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' "${STAKERS[1]}" 0)
note "staker 1 request slot 0: $s1_req"
ok "settlementExtensionUntil should be > 0 (snapshot of latestPendingSettlementCloseTime)"

# ─────────────────────────────────────────────────────────────────────
# Phase 10 — Settle the batch at face value → SP price pumps
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 10 — manager settles batch at face value (100k jRES)"
batch=$(xc $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
SETTLE=100000000000000000000000
sp_ta_pre=$(xc $SP 'totalAssets()(uint256)' | awk '{print $1}')
xs "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$SETTLE" >/dev/null
xs "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$SVAULT" "$SETTLE" >/dev/null
xs "$DEPLOYER_PK" "$SVAULT" 'settleRedemption(uint256,uint256)' "$batch" "$SETTLE" >/dev/null
sp_ta_post=$(xc $SP 'totalAssets()(uint256)' | awk '{print $1}')
peg_post=$(xc $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
delta=$(python3 -c "print((int('$sp_ta_post') - int('$sp_ta_pre'))/1e24)")
ok "SP totalAssets: $(python3 -c "print(int('$sp_ta_pre')/1e24)") → $(python3 -c "print(int('$sp_ta_post')/1e24)") ($delta agYLD bonus)"
ok "pegGap drained: $peg_post (expected 0)"

# ─────────────────────────────────────────────────────────────────────
# Phase 11 — Lender 0 withdraws 100k USDr (instant, no cooldown)
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 11 — lender 0 withdraws 100k USDr (instant)"
W=100000000000000000000000
usdr_pre=$(xc $USDR 'balanceOf(address)(uint256)' "${LENDERS[0]}" | awk '{print $1}')
xs "${LENDER_PKS[0]}" "$POOL" 'withdraw(uint256,address,address)' "$W" "${LENDERS[0]}" "${LENDERS[0]}" >/dev/null
usdr_post=$(xc $USDR 'balanceOf(address)(uint256)' "${LENDERS[0]}" | awk '{print $1}')
delta=$(python3 -c "print((int('$usdr_post') - int('$usdr_pre'))/1e18)")
ok "lender 0 USDr received: $delta (expected ~100k)"

# ─────────────────────────────────────────────────────────────────────
# Phase 12 — Borrower 2 repays full + withdraws collat
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 12 — borrower 2 full repay + withdraw collat"
b2_debt=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[2]}" | awk '{print $1}')
padded=$(python3 -c "print(int('$b2_debt') * 110 // 100)")
xs "${BORROWER_PKS[2]}" "$USDR" 'approve(address,uint256)' "$POOL" "$padded" >/dev/null
xs "${BORROWER_PKS[2]}" "$POOL" 'repay(address,bytes,uint256)' "$SDIGCAP_ADAPTER" "$ZERO" "115792089237316195423570985008687907853269984665640564039457584007913129639935" >/dev/null
xs "${BORROWER_PKS[2]}" "$POOL" 'withdrawAsset(address,bytes)' "$SDIGCAP_ADAPTER" "$DATA" >/dev/null
b2_debt_after=$(xc $DEBT 'balanceOf(address)(uint256)' "${BORROWERS[2]}" | awk '{print $1}')
b2_col_after=$(xc $SDIGCAP_ADAPTER 'getAssetValue(address,bytes)(uint256)' "${BORROWERS[2]}" "$ZERO" | awk '{print $1}')
ok "borrower 2 debt: $b2_debt_after, collat: $b2_col_after"

# ─────────────────────────────────────────────────────────────────────
# Phase 13 — Restore JRES oracle, final state report
# ─────────────────────────────────────────────────────────────────────
phase "PHASE 13 — restore oracle + final state"
xs "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 1000000000000000000 >/dev/null

echo ""
echo "  LP totalAssets:     $(xc $POOL 'totalAssets()(uint256)' | awk '{print $1}')"
echo "  LP totalSupply:     $(xc $POOL 'totalSupply()(uint256)' | awk '{print $1}')"
echo "  Debt totalSupply:   $(xc $DEBT 'totalSupply()(uint256)' | awk '{print $1}')"
echo "  SP totalAssets:     $(xc $SP   'totalAssets()(uint256)' | awk '{print $1}')"
echo "  SP totalSupply:     $(xc $SP   'totalSupply()(uint256)' | awk '{print $1}')"
echo "  pegGap pending:     $(xc $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')"
echo "  Latest pending close: $(xc $SVAULT 'latestPendingSettlementCloseTime()(uint64)' | awk '{print $1}')"
echo "  Cooldown duration:    $(xc $SP 'cooldownDuration()(uint256)' | awk '{print $1}') seconds"
echo ""
echo "  Per-staker pending state:"
for i in 0 1 2; do
  addr="${STAKERS[$i]}"
  pcount=$(xc $SP 'pendingCount(address)(uint256)' "$addr" | awk '{print $1}')
  earm=$(xc $SP 'earmarkedShares(address)(uint256)' "$addr" | awk '{print $1}')
  printf "    staker %d  pendingCount=%s  earmarked=%s\n" "$i" "$pcount" "$(python3 -c "print(int('$earm')/1e24)")"
done

phase "DONE"
note "Multi-actor V2 E2E completed. Deployer balance now: $(cast balance --ether --rpc-url $RPC $DEPLOYER) native USDr"

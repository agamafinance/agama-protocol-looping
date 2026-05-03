#!/usr/bin/env bash
# Live agYLD/sagYLD stress — exercises every state transition that can
# happen to the two yield tokens, with explicit revert assertions.
# Idempotent: every numeric assertion compares against a per-wallet
# delta, not an absolute, so re-running the script never fights stale
# residual balances.
#
# Coverage (live chain, no time skipping):
#   T1  agYLD transfer between wallets (vanilla ERC-4626 share)
#   T2  sagYLD transfer (vanilla ERC-20 — commitment device, NOT locked)
#   T3  sagYLD transfer AFTER requestUnstake → balance forfeit
#   T4  Two parallel requestUnstake (different request ids)
#   T5  Claim BEFORE cooldown elapsed → must revert
#   T6  requestUnstake exceeding free balance → must revert
#   T7  agYLD drain transfer
#   T8  Read protocol-wide views
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"; ME="$DEPLOYER"
RPC="$RAYLS_TESTNET_RPC"

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1; }
xs_quiet() { xs "$@" | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }

phase(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }
ko(){ printf "    ✗ %s\n" "$1"; STRESS_FAIL=1; }
expect_revert() {
  local out="$1" label="$2"
  if echo "$out" | grep -qiE "Error|revert"; then ok "$label reverted as expected"
  else ko "$label did NOT revert — output: ${out:0:100}"; fi
}
assert_delta_eq() {
  local got="$1" expected="$2" label="$3"
  if [ "$got" = "$expected" ]; then ok "$label delta matches expected"
  else
    local got_h=$(python3 -c "print(int('$got')/1e24)" 2>/dev/null || echo "$got")
    local exp_h=$(python3 -c "print(int('$expected')/1e24)" 2>/dev/null || echo "$expected")
    ko "$label delta = $got_h, expected $exp_h"
  fi
}

STRESS_FAIL=0

# Use fresh wallets — RETAIL_3 RETAIL_4 CONSERVATIVE_0 untouched by
# the earlier seed run.
P_PK="$RETAIL_3_PK"; P="$RETAIL_3_ADDR"
Q_PK="$RETAIL_4_PK"; Q="$RETAIL_4_ADDR"
R_PK="$CONSERVATIVE_0_PK"; R="$CONSERVATIVE_0_ADDR"

echo "════════════════════════════════════════════════════════"
echo "  agYLD / sagYLD live stress  (delta-based)"
echo "  P=$P"
echo "  Q=$Q"
echo "  R=$R"
echo "════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────
# Setup: P+Q each deposit USDr → agYLD
# ─────────────────────────────────────────────────────────────────────
phase "setup-1: P deposits 80k USDr → agYLD"
xs_quiet "$PK" "$USDR" 'mint(address,uint256)' "$P" 100000000000000000000000 >/dev/null
xs_quiet "$P_PK" "$USDR" 'approve(address,uint256)' "$POOL" 80000000000000000000000 >/dev/null
xs_quiet "$P_PK" "$POOL" 'deposit(uint256,address)' 80000000000000000000000 "$P" >/dev/null
agP_pre=$(xc $POOL 'balanceOf(address)(uint256)' $P)
ok "P agYLD = $(python3 -c "print(int('$agP_pre')/1e24)")"

phase "setup-2: Q deposits 60k USDr → agYLD"
xs_quiet "$PK" "$USDR" 'mint(address,uint256)' "$Q" 80000000000000000000000 >/dev/null
xs_quiet "$Q_PK" "$USDR" 'approve(address,uint256)' "$POOL" 60000000000000000000000 >/dev/null
xs_quiet "$Q_PK" "$POOL" 'deposit(uint256,address)' 60000000000000000000000 "$Q" >/dev/null
agQ_pre=$(xc $POOL 'balanceOf(address)(uint256)' $Q)
ok "Q agYLD = $(python3 -c "print(int('$agQ_pre')/1e24)")"

# ─────────────────────────────────────────────────────────────────────
# T1 — agYLD transfer (delta-based)
# ─────────────────────────────────────────────────────────────────────
phase "T1: P → R 10k agYLD (delta-based assertion)"
TEN_K_AG=10000000000000000000000000000  # 10k * 1e24
agR_pre=$(xc $POOL 'balanceOf(address)(uint256)' $R)
xs_quiet "$P_PK" "$POOL" 'transfer(address,uint256)' "$R" "$TEN_K_AG" >/dev/null
agR_post=$(xc $POOL 'balanceOf(address)(uint256)' $R)
delta=$(python3 -c "print(int('$agR_post') - int('$agR_pre'))")
assert_delta_eq "$delta" "$TEN_K_AG" "R agYLD"

# ─────────────────────────────────────────────────────────────────────
# T2 — sagYLD vanilla transfer
# ─────────────────────────────────────────────────────────────────────
phase "T2: Q stakes all → sagYLD, transfer 5k → R (vanilla ERC-20 ✓)"
xs_quiet "$Q_PK" "$POOL" 'approve(address,uint256)' "$SP" "$agQ_pre" >/dev/null
xs_quiet "$Q_PK" "$SP" 'deposit(uint256,address)' "$agQ_pre" "$Q" >/dev/null
sagQ=$(xc $SP 'balanceOf(address)(uint256)' $Q)
ok "Q sagYLD post-stake = $(python3 -c "print(int('$sagQ')/1e24)")"
FIVE_K_SAG=5000000000000000000000000000
sagR_pre=$(xc $SP 'balanceOf(address)(uint256)' $R)
xs_quiet "$Q_PK" "$SP" 'transfer(address,uint256)' "$R" "$FIVE_K_SAG" >/dev/null
sagR_post=$(xc $SP 'balanceOf(address)(uint256)' $R)
sag_delta=$(python3 -c "print(int('$sagR_post') - int('$sagR_pre'))")
assert_delta_eq "$sag_delta" "$FIVE_K_SAG" "R sagYLD"

# ─────────────────────────────────────────────────────────────────────
# T3 — Forfeit-on-transfer: P stakes 30k, requests half, transfers all
# ─────────────────────────────────────────────────────────────────────
phase "T3: P stakes 30k, requestUnstake half, transfer remaining sagYLD → balance 0"
THIRTY_K_AG=30000000000000000000000000000
xs_quiet "$P_PK" "$POOL" 'approve(address,uint256)' "$SP" "$THIRTY_K_AG" >/dev/null
xs_quiet "$P_PK" "$SP" 'deposit(uint256,address)' "$THIRTY_K_AG" "$P" >/dev/null
sagP=$(xc $SP 'balanceOf(address)(uint256)' $P)
half_sagP=$(python3 -c "print(int('$sagP') // 2)")
xs_quiet "$P_PK" "$SP" 'requestUnstake(uint256)' "$half_sagP" >/dev/null
emP=$(xc $SP 'earmarkedShares(address)(uint256)' $P)
ok "P earmarked = $(python3 -c "print(int('$emP')/1e24)")"
xs_quiet "$P_PK" "$SP" 'transfer(address,uint256)' "$Q" "$sagP" >/dev/null
sagP_post=$(xc $SP 'balanceOf(address)(uint256)' $P)
if [ "$sagP_post" = "0" ]; then ok "P sagYLD drained to 0 (request shares forfeit ✓)"
else ko "P residual = $sagP_post"; fi

# ─────────────────────────────────────────────────────────────────────
# T4 — Two parallel requestUnstake (different request ids)
# ─────────────────────────────────────────────────────────────────────
phase "T4: R issues two staggered requestUnstake on its 5k sagYLD"
sagR_now=$(xc $SP 'balanceOf(address)(uint256)' $R)
ok "R sagYLD = $(python3 -c "print(int('$sagR_now')/1e24)")"
third=$(python3 -c "print(int('$sagR_now') // 4)")
emR_pre=$(xc $SP 'earmarkedShares(address)(uint256)' $R)
xs_quiet "$R_PK" "$SP" 'requestUnstake(uint256)' "$third" >/dev/null
xs_quiet "$R_PK" "$SP" 'requestUnstake(uint256)' "$third" >/dev/null
emR_post=$(xc $SP 'earmarkedShares(address)(uint256)' $R)
delta_em=$(python3 -c "print(int('$emR_post') - int('$emR_pre'))")
expected_em=$(python3 -c "print(int('$third') * 2)")
assert_delta_eq "$delta_em" "$expected_em" "R earmarked"

# ─────────────────────────────────────────────────────────────────────
# T5 — Claim BEFORE cooldown elapsed must revert (eth_call simulation)
# ─────────────────────────────────────────────────────────────────────
phase "T5: R claim id=0 immediately → must revert (CooldownNotElapsed)"
out=$(cast call --rpc-url "$RPC" --from "$R" "$SP" 'claim(uint256)' 0 2>&1)
expect_revert "$out" "claim before cooldown"

# ─────────────────────────────────────────────────────────────────────
# T6 — requestUnstake > free balance must revert
# ─────────────────────────────────────────────────────────────────────
phase "T6: R requests > free balance → must revert"
sagR_now=$(xc $SP 'balanceOf(address)(uint256)' $R)
big=$(python3 -c "print(int('$sagR_now') * 10)")
out=$(cast call --rpc-url "$RPC" --from "$R" "$SP" 'requestUnstake(uint256)' "$big" 2>&1)
expect_revert "$out" "request > free balance"

# ─────────────────────────────────────────────────────────────────────
# T7 — drain transfer (P → R)
# ─────────────────────────────────────────────────────────────────────
phase "T7: P transfers all remaining agYLD → R (drain to 0)"
agP_now=$(xc $POOL 'balanceOf(address)(uint256)' $P)
if [ "$agP_now" != "0" ]; then
  xs_quiet "$P_PK" "$POOL" 'transfer(address,uint256)' "$R" "$agP_now" >/dev/null
fi
agP_post=$(xc $POOL 'balanceOf(address)(uint256)' $P)
if [ "$agP_post" = "0" ]; then ok "P agYLD drained to 0 ✓"
else ko "P residual = $agP_post"; fi

# ─────────────────────────────────────────────────────────────────────
# T8 — protocol view sanity
# ─────────────────────────────────────────────────────────────────────
phase "T8: protocol view sanity"
ta=$(xc $POOL 'totalAssets()(uint256)')
ts=$(xc $POOL 'totalSupply()(uint256)')
spta=$(xc $SP 'totalAssets()(uint256)')
spts=$(xc $SP 'totalSupply()(uint256)')
ok "Pool totalAssets = $(python3 -c "print(int('$ta')/1e18)")"
ok "Pool totalSupply = $(python3 -c "print(int('$ts')/1e24)")"
ok "SP   totalAssets = $(python3 -c "print(int('$spta')/1e24)")"
ok "SP   totalSupply = $(python3 -c "print(int('$spts')/1e24)")"

echo ""
echo "════════════════════════════════════════════════════════"
if [ $STRESS_FAIL -eq 0 ]; then
  echo "  ✓ STRESS PASS — agYLD/sagYLD invariants hold on chain"
else
  echo "  ✗ STRESS FAIL — see ✗ above"
fi
echo "════════════════════════════════════════════════════════"
exit $STRESS_FAIL

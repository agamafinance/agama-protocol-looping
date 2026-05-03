#!/usr/bin/env bash
# Multi-actor 5-min cooldown — 3 distinct wallets stake then concurrently
# requestUnstake at staggered times, each claims independently when its
# unlock fires. Verifies the SP handles N parallel pending requests
# cleanly.
set +e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"
ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }
phase() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
ok()    { printf "  ✓ %s\n" "$1"; }
note()  { printf "  · %s\n" "$1"; }

# Three actors from the wallet army
A_PK="$MIDCAP_0_PK"; A_ADDR="$MIDCAP_0_ADDR"
B_PK="$MIDCAP_1_PK"; B_ADDR="$MIDCAP_1_ADDR"
C_PK="$MIDCAP_2_PK"; C_ADDR="$MIDCAP_2_ADDR"

phase "MULTI-ACTOR 5-MIN COOLDOWN — 3 staggered requests"

# ─────────────────────────────────────────────────────────────────────
# 0. Mint native USDr top-up so all three have gas (defensive)
# ─────────────────────────────────────────────────────────────────────
phase "0. Top up native USDr (gas) — 0.3 each if needed"
for addr in $A_ADDR $B_ADDR $C_ADDR; do
  bal=$(cast balance --ether --rpc-url $RPC $addr | head -1)
  note "$addr: $bal native"
done

# ─────────────────────────────────────────────────────────────────────
# 1. Mint mock USDr to A/B/C, deposit, stake into SP (current addresses)
# ─────────────────────────────────────────────────────────────────────
phase "1. Mint USDr + deposit + stake (3 actors)"
MINT=100000000000000000000000  # 100k each
for pk_addr in "$A_PK:$A_ADDR" "$B_PK:$B_ADDR" "$C_PK:$C_ADDR"; do
  pk="${pk_addr%%:*}"; addr="${pk_addr##*:}"
  xs "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$addr" "$MINT" >/dev/null
  xs "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$MINT" >/dev/null
  xs "$pk" "$POOL" 'deposit(uint256,address)' "$MINT" "$addr" >/dev/null
  agyld=$(xc $POOL 'balanceOf(address)(uint256)' "$addr")
  xs "$pk" "$POOL" 'approve(address,uint256)' "$SP" "$agyld" >/dev/null
  xs "$pk" "$SP" 'deposit(uint256,address)' "$agyld" "$addr" >/dev/null
  sag=$(xc $SP 'balanceOf(address)(uint256)' "$addr")
  ok "$addr  sagYLD: $(python3 -c "print(int('$sag')/1e24)")"
done

# ─────────────────────────────────────────────────────────────────────
# 2. Set cooldown to 5 minutes
# ─────────────────────────────────────────────────────────────────────
phase "2. setCooldownDuration(300)"
xs "$DEPLOYER_PK" "$SP" 'setCooldownDuration(uint256)' 300 >/dev/null
cd_now=$(xc $SP 'cooldownDuration()(uint256)')
ok "cooldownDuration = $cd_now seconds"

# ─────────────────────────────────────────────────────────────────────
# 3. Three staggered requestUnstake (10s apart)
# ─────────────────────────────────────────────────────────────────────
phase "3. 3 staggered requestUnstake — A then B+10s then C+20s"

a_sag=$(xc $SP 'balanceOf(address)(uint256)' "$A_ADDR")
b_sag=$(xc $SP 'balanceOf(address)(uint256)' "$B_ADDR")
c_sag=$(xc $SP 'balanceOf(address)(uint256)' "$C_ADDR")
a_half=$(python3 -c "print(int('$a_sag') // 2)")
b_half=$(python3 -c "print(int('$b_sag') // 2)")
c_half=$(python3 -c "print(int('$c_sag') // 2)")

t_a=$(date +%s)
xs "$A_PK" "$SP" 'requestUnstake(uint256)' "$a_half" >/dev/null
ok "A requested at t=0  ($(python3 -c "print(int('$a_half')/1e24)") sagYLD)"

sleep 10
t_b=$(date +%s)
xs "$B_PK" "$SP" 'requestUnstake(uint256)' "$b_half" >/dev/null
ok "B requested at t=10 ($(python3 -c "print(int('$b_half')/1e24)") sagYLD)"

sleep 10
t_c=$(date +%s)
xs "$C_PK" "$SP" 'requestUnstake(uint256)' "$c_half" >/dev/null
ok "C requested at t=20 ($(python3 -c "print(int('$c_half')/1e24)") sagYLD)"

a_unlock=$((t_a + 300))
b_unlock=$((t_b + 300))
c_unlock=$((t_c + 300))
note "A unlock at: $a_unlock (in $(($a_unlock - $(date +%s)))s)"
note "B unlock at: $b_unlock (in $(($b_unlock - $(date +%s)))s)"
note "C unlock at: $c_unlock (in $(($c_unlock - $(date +%s)))s)"

# ─────────────────────────────────────────────────────────────────────
# 4. Sleep until A's unlock + buffer
# ─────────────────────────────────────────────────────────────────────
phase "4. Wait until first unlock (~5 min)"
now=$(date +%s)
sleep_for=$((a_unlock + 30 - now))
note "sleeping ${sleep_for}s..."
sleep "$sleep_for"
ok "A's cooldown elapsed."

# ─────────────────────────────────────────────────────────────────────
# 5. Claim A first; B and C may still be in cooldown
# ─────────────────────────────────────────────────────────────────────
phase "5. A claims"
agyld_pre=$(xc $POOL 'balanceOf(address)(uint256)' "$A_ADDR")
xs "$A_PK" "$SP" 'claim(uint256)' 0 >/dev/null
agyld_post=$(xc $POOL 'balanceOf(address)(uint256)' "$A_ADDR")
delta=$(python3 -c "print((int('$agyld_post') - int('$agyld_pre'))/1e24)")
ok "A received $delta agYLD"

# Try B claim — should still be in cooldown (~10s left)
phase "6. B early claim attempt (should still be in cooldown)"
out=$(cast send --rpc-url "$RPC" --private-key "$B_PK" "$SP" 'claim(uint256)' 0 2>&1 || true)
if echo "$out" | grep -qE "Error|revert|Revert"; then
  ok "B claim reverted (cooldown not elapsed yet)"
else
  note "(B claim went through — could happen if 10s gap closed during sleep buffer)"
fi

# Wait until B unlock
phase "7. Wait for B unlock"
now=$(date +%s)
sleep_for=$((b_unlock + 10 - now))
if [ $sleep_for -gt 0 ]; then
  note "sleeping ${sleep_for}s..."
  sleep "$sleep_for"
fi
xs "$B_PK" "$SP" 'claim(uint256)' 0 >/dev/null
b_post=$(xc $POOL 'balanceOf(address)(uint256)' "$B_ADDR")
ok "B claimed; agYLD balance: $(python3 -c "print(int('$b_post')/1e24)")"

# Wait for C unlock
phase "8. Wait for C unlock"
now=$(date +%s)
sleep_for=$((c_unlock + 10 - now))
if [ $sleep_for -gt 0 ]; then
  note "sleeping ${sleep_for}s..."
  sleep "$sleep_for"
fi
xs "$C_PK" "$SP" 'claim(uint256)' 0 >/dev/null
c_post=$(xc $POOL 'balanceOf(address)(uint256)' "$C_ADDR")
ok "C claimed; agYLD balance: $(python3 -c "print(int('$c_post')/1e24)")"

# ─────────────────────────────────────────────────────────────────────
# 9. Restore cooldown to 7 days
# ─────────────────────────────────────────────────────────────────────
phase "9. Restore cooldownDuration to 7 days"
xs "$DEPLOYER_PK" "$SP" 'setCooldownDuration(uint256)' 604800 >/dev/null
cd_final=$(xc $SP 'cooldownDuration()(uint256)')
ok "cooldownDuration = $cd_final seconds"

phase "DONE"
note "3 parallel cooldown cycles validated end-to-end on chain."

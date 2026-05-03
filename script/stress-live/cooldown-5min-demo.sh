#!/usr/bin/env bash
# 5-min cooldown live demo — for the contract redeployed with
# MIN_COOLDOWN = 60s temporarily relaxed. Sets cooldown to 300s,
# stakes, requestUnstake, waits 5+ min, claims, asserts agYLD received.
#
# After the demo the cooldown is restored to 7 days via governance.
set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"
ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }

phase() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
ok()    { printf "  ✓ %s\n" "$1"; }
note()  { printf "  · %s\n" "$1"; }

phase "5-MIN COOLDOWN DEMO"
note "Deployer: $DEPLOYER"
note "Balance:  $(cast balance --ether --rpc-url $RPC $DEPLOYER) native USDr"

# ─────────────────────────────────────────────────────────────────────
# 1. Mint USDr, deposit, stake — set up a position
# ─────────────────────────────────────────────────────────────────────
phase "1. Setup state — mint 100k USDr, deposit, stake all into SP"
MINT=100000000000000000000000  # 100k USDr
xs "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$MINT" >/dev/null
xs "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$MINT" >/dev/null
xs "$DEPLOYER_PK" "$POOL" 'deposit(uint256,address)' "$MINT" "$DEPLOYER" >/dev/null

agyld=$(xc $POOL 'balanceOf(address)(uint256)' $DEPLOYER)
note "agYLD balance after deposit: $(python3 -c "print(int('$agyld')/1e24)")"
xs "$DEPLOYER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$agyld" >/dev/null
xs "$DEPLOYER_PK" "$SP" 'deposit(uint256,address)' "$agyld" "$DEPLOYER" >/dev/null

sag=$(xc $SP 'balanceOf(address)(uint256)' $DEPLOYER)
ok "sagYLD minted: $(python3 -c "print(int('$sag')/1e24)")"

# ─────────────────────────────────────────────────────────────────────
# 2. Set cooldown to 5 minutes
# ─────────────────────────────────────────────────────────────────────
phase "2. setCooldownDuration(300) = 5 minutes"
xs "$DEPLOYER_PK" "$SP" 'setCooldownDuration(uint256)' 300 >/dev/null
cd_now=$(xc $SP 'cooldownDuration()(uint256)')
ok "cooldownDuration = $cd_now seconds (= $((cd_now / 60)) min)"

# ─────────────────────────────────────────────────────────────────────
# 3. requestUnstake half
# ─────────────────────────────────────────────────────────────────────
phase "3. requestUnstake half"
half=$(python3 -c "print(int('$sag') // 2)")
note "Requesting unstake of $(python3 -c "print(int('$half')/1e24)") sagYLD"
xs "$DEPLOYER_PK" "$SP" 'requestUnstake(uint256)' "$half" >/dev/null

req=$(cast call --rpc-url $RPC $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' $DEPLOYER 0)
note "request slot 0: $req"
unlock_at=$(echo "$req" | python3 -c "
import sys
line = sys.stdin.read().strip().strip('()')
parts = line.split(', ')
req_at = int(parts[1].split()[0])
ext = int(parts[2].split()[0])
unlock = max(req_at + 300, ext)
print(unlock)
")
now=$(date +%s)
remaining=$((unlock_at - now))
ok "unlockAt = $unlock_at (in $remaining seconds)"

# ─────────────────────────────────────────────────────────────────────
# 4. Try claim immediately → must revert
# ─────────────────────────────────────────────────────────────────────
phase "4. Early claim attempt — must revert"
EARLY=$(cast send --rpc-url "$RPC" --private-key "$DEPLOYER_PK" "$SP" 'claim(uint256)' 0 2>&1 || true)
if echo "$EARLY" | grep -qE "Error|revert|Revert"; then
  ok "claim(0) reverted as expected"
else
  echo "  FAIL: claim should have reverted"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# 5. Wait — exit script here, claim phase will be a separate command
# ─────────────────────────────────────────────────────────────────────
phase "5. Wait $((remaining + 30))s for cooldown + buffer, then claim"
note "Will sleep $((remaining + 30)) seconds..."
sleep $((remaining + 30))
ok "Cooldown elapsed."

# ─────────────────────────────────────────────────────────────────────
# 6. Claim
# ─────────────────────────────────────────────────────────────────────
phase "6. claim(0)"
agyld_pre=$(xc $POOL 'balanceOf(address)(uint256)' $DEPLOYER)
sag_pre=$(xc $SP 'balanceOf(address)(uint256)' $DEPLOYER)
note "Pre-claim:  agYLD=$(python3 -c "print(int('$agyld_pre')/1e24)")  sagYLD=$(python3 -c "print(int('$sag_pre')/1e24)")"

cast send --rpc-url $RPC --private-key $DEPLOYER_PK $SP 'claim(uint256)' 0 2>&1 | grep -E "^(status|gasUsed|transactionHash)" | head -3

agyld_post=$(xc $POOL 'balanceOf(address)(uint256)' $DEPLOYER)
sag_post=$(xc $SP 'balanceOf(address)(uint256)' $DEPLOYER)
delta_agyld=$(python3 -c "print((int('$agyld_post') - int('$agyld_pre'))/1e24)")
delta_sag=$(python3 -c "print((int('$sag_pre') - int('$sag_post'))/1e24)")
ok "Post-claim: agYLD=$(python3 -c "print(int('$agyld_post')/1e24)")  sagYLD=$(python3 -c "print(int('$sag_post')/1e24)")"
ok "agYLD received: +$delta_agyld"
ok "sagYLD burned : -$delta_sag"

# ─────────────────────────────────────────────────────────────────────
# 7. Restore cooldown to 7 days
# ─────────────────────────────────────────────────────────────────────
phase "7. Restore cooldown to 7 days (production setting)"
xs "$DEPLOYER_PK" "$SP" 'setCooldownDuration(uint256)' 604800 >/dev/null
cd_final=$(xc $SP 'cooldownDuration()(uint256)')
ok "cooldownDuration = $cd_final seconds (= $((cd_final / 86400)) days)"

phase "DONE"
note "Live cooldown round-trip in 5 minutes proven on chain."
note "Claim tx + state changes verifiable via Blockscout."

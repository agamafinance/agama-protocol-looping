#!/usr/bin/env bash
# Live E2E for the V2 SP cooldown — stake, requestUnstake, verify state,
# attempt early claim (must revert), then optionally lower cooldownDuration
# to 1 day for the demo to allow claiming "tomorrow".
#
# Prereqs:
#   - Fresh redeploy with the cooldown SP (Deploy.s.sol committed in
#     d0db3d6).
#   - test-front already pointing at the new addresses (extract-abis run
#     after redeploy).
#
# Reads only require addresses; writes require deployer key (PRIVATE_KEY
# in smart/.env) since we use the deployer wallet.
set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"

assert_eq() {
  local label="$1"; local exp="$2"; local act="$3"
  if [ "$exp" = "$act" ]; then
    printf "  PASS   %-50s = %s\n" "$label" "$act"
  else
    printf "  FAIL   %-50s exp=%s act=%s\n" "$label" "$exp" "$act"
    exit 1
  fi
}

assert_revert() {
  local label="$1"; local out="$2"
  if echo "$out" | grep -q "Error\|revert\|Revert"; then
    printf "  PASS   %-50s reverted as expected\n" "$label"
  else
    printf "  FAIL   %-50s did not revert: %s\n" "$label" "$out"
    exit 1
  fi
}

section "COOLDOWN E2E — fresh redeploy"
kv "Deployer balance" "$(deployer_balance) USDr (gas)"

# ─────────────────────────────────────────────────────────────────────
# 1. Mint USDr to deployer (public mock)
# ─────────────────────────────────────────────────────────────────────
section "1. Mint 1M USDr"
MINT=1000000000000000000000000  # 1M
send "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$MINT"
USDR_BAL=$(call $USDR 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
echo "  USDr balance: $USDR_BAL"

# ─────────────────────────────────────────────────────────────────────
# 2. LP deposit 100k USDr → mint agYLD
# ─────────────────────────────────────────────────────────────────────
section "2. LP deposit 100k USDr"
DEPOSIT=100000000000000000000000  # 100k
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$DEPOSIT"
send "$DEPLOYER_PK" "$POOL" 'deposit(uint256,address)' "$DEPOSIT" "$DEPLOYER"

AGYLD_BAL=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
# 100k USDr at offset 6 = 1e29 wei agYLD = 100k @ 24 dec.
assert_eq "agYLD minted (1e29 wei = 100k @ 24dec)" "100000000000000000000000000000" "$AGYLD_BAL"

# ─────────────────────────────────────────────────────────────────────
# 3. Stake 100k agYLD into SP → sagYLD 1:1
# ─────────────────────────────────────────────────────────────────────
section "3. Stake 100k agYLD into SP"
send "$DEPLOYER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$AGYLD_BAL"
send "$DEPLOYER_PK" "$SP"   'deposit(uint256,address)' "$AGYLD_BAL" "$DEPLOYER"

SAGYLD_BAL=$(call $SP 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "sagYLD minted (1:1 with agYLD)" "$AGYLD_BAL" "$SAGYLD_BAL"

# ─────────────────────────────────────────────────────────────────────
# 4. cooldownDuration default = 7 days
# ─────────────────────────────────────────────────────────────────────
section "4. Cooldown duration check"
COOLDOWN=$(call $SP 'cooldownDuration()(uint256)' | awk '{print $1}')
assert_eq "cooldownDuration default (7 days = 604800s)" "604800" "$COOLDOWN"

# ─────────────────────────────────────────────────────────────────────
# 5. Lower cooldown to MIN (1 day) for demo claim "tomorrow"
# ─────────────────────────────────────────────────────────────────────
section "5. Governance: setCooldownDuration(1 day) for demo"
ONE_DAY=86400
send "$DEPLOYER_PK" "$SP" 'setCooldownDuration(uint256)' "$ONE_DAY"
COOLDOWN_NOW=$(call $SP 'cooldownDuration()(uint256)' | awk '{print $1}')
assert_eq "cooldownDuration after governance change" "$ONE_DAY" "$COOLDOWN_NOW"

# ─────────────────────────────────────────────────────────────────────
# 6. requestUnstake half of position
# ─────────────────────────────────────────────────────────────────────
section "6. requestUnstake 50k sagYLD"
HALF=$(python3 -c "print(int('$SAGYLD_BAL') // 2)")
send "$DEPLOYER_PK" "$SP" 'requestUnstake(uint256)' "$HALF"

PENDING_COUNT=$(call $SP 'pendingCount(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "pendingCount" "1" "$PENDING_COUNT"
EARMARKED=$(call $SP 'earmarkedShares(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "earmarkedShares" "$HALF" "$EARMARKED"

# Read the request slot
REQ_RAW=$(call $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' $DEPLOYER 0 2>&1)
echo "  Request slot 0:"
echo "    $REQ_RAW"

# ─────────────────────────────────────────────────────────────────────
# 7. Try to claim immediately → must revert with CooldownNotElapsed
# ─────────────────────────────────────────────────────────────────────
section "7. Early claim must revert"
EARLY_CLAIM=$(cast send --rpc-url "$RPC" --private-key "$DEPLOYER_PK" "$SP" 'claim(uint256)' 0 2>&1 || true)
assert_revert "claim(0) before cooldown elapsed" "$EARLY_CLAIM"

# ─────────────────────────────────────────────────────────────────────
# 8. sagYLD is transferable (V2 — cooldown lives in queue, not token)
# ─────────────────────────────────────────────────────────────────────
section "8. sagYLD transfer (V2 transferable token)"
RECIPIENT=0x000000000000000000000000000000000000dEaD
TINY=1000000000000000000  # 1 wei agaSP-equivalent (well, 1e18 wei, ~1e-6 sagYLD)
send "$DEPLOYER_PK" "$SP" 'transfer(address,uint256)' "$RECIPIENT" "$TINY"
DEAD_BAL=$(call $SP 'balanceOf(address)(uint256)' $RECIPIENT | awk '{print $1}')
assert_eq "transfer to 0xdead succeeded" "$TINY" "$DEAD_BAL"

# ─────────────────────────────────────────────────────────────────────
# 9. Final state — user must come back ~24h later to claim
# ─────────────────────────────────────────────────────────────────────
section "DONE — cooldown live, claim available in ~24h"
echo "  Deployer agYLD:     $(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER)"
echo "  Deployer sagYLD:    $(call $SP   'balanceOf(address)(uint256)' $DEPLOYER)"
echo "  earmarkedShares:    $EARMARKED"
echo "  pendingCount:       1"
echo "  cooldownDuration:   $COOLDOWN_NOW seconds (1 day)"
echo ""
echo "  To claim: come back ~24h after the requestUnstake tx and run"
echo "  cast send --rpc-url \$RAYLS_TESTNET_RPC --private-key \$PRIVATE_KEY \\"
echo "    $SP 'claim(uint256)' 0"

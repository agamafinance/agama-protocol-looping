#!/usr/bin/env bash
# Seed 6 wallets with deliberately diverse on-chain states so the front
# UX can be hand-tested wallet-by-wallet:
#
#   A WHALE_0   pure agYLD holder
#   B WHALE_1   pure sagYLD staker
#   C WHALE_2   mixed agYLD + sagYLD
#   D WHALE_3   safe borrower (sRESOLV collat, low debt) → HF very high
#   E WHALE_4   borderline borrower (jRESOLV collat, high debt) → HF ~1.5
#   F MIDCAP_3  cooldown-pending staker (requestUnstake half, claim pending)
#
# Idempotent-ish: re-running will keep adding to balances. Designed to be
# run once after a fresh redeploy.
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"; ME="$DEPLOYER"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }

phase(){ echo ""; echo "════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════"; }
sub(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────
# Wallet A (WHALE_0)  — pure agYLD holder (no SP)
# ─────────────────────────────────────────────────────────────────────
A_PK="$WHALE_0_PK"; A="$WHALE_0_ADDR"; A_LABEL="A WHALE_0  pure-agYLD"

phase "$A_LABEL  $A"
xs "$PK" "$USDR" 'mint(address,uint256)' "$A" 200000000000000000000000 >/dev/null
xs "$A_PK" "$USDR" 'approve(address,uint256)' "$POOL" 100000000000000000000000 >/dev/null
xs "$A_PK" "$POOL" 'deposit(uint256,address)' 100000000000000000000000 "$A" >/dev/null
ok "deposited 100k USDr → agYLD; nothing staked"

# ─────────────────────────────────────────────────────────────────────
# Wallet B (WHALE_1)  — pure sagYLD staker
# ─────────────────────────────────────────────────────────────────────
B_PK="$WHALE_1_PK"; B="$WHALE_1_ADDR"; B_LABEL="B WHALE_1  pure-sagYLD"

phase "$B_LABEL  $B"
xs "$PK" "$USDR" 'mint(address,uint256)' "$B" 200000000000000000000000 >/dev/null
xs "$B_PK" "$USDR" 'approve(address,uint256)' "$POOL" 100000000000000000000000 >/dev/null
xs "$B_PK" "$POOL" 'deposit(uint256,address)' 100000000000000000000000 "$B" >/dev/null
agB=$(xc $POOL 'balanceOf(address)(uint256)' $B)
xs "$B_PK" "$POOL" 'approve(address,uint256)' "$SP" "$agB" >/dev/null
xs "$B_PK" "$SP" 'deposit(uint256,address)' "$agB" "$B" >/dev/null
ok "deposited 100k USDr → agYLD; staked ALL → sagYLD"

# ─────────────────────────────────────────────────────────────────────
# Wallet C (WHALE_2)  — mixed
# ─────────────────────────────────────────────────────────────────────
C_PK="$WHALE_2_PK"; C="$WHALE_2_ADDR"; C_LABEL="C WHALE_2  mixed"

phase "$C_LABEL  $C"
xs "$PK" "$USDR" 'mint(address,uint256)' "$C" 200000000000000000000000 >/dev/null
xs "$C_PK" "$USDR" 'approve(address,uint256)' "$POOL" 150000000000000000000000 >/dev/null
xs "$C_PK" "$POOL" 'deposit(uint256,address)' 150000000000000000000000 "$C" >/dev/null
agC=$(xc $POOL 'balanceOf(address)(uint256)' $C)
half_C=$(python3 -c "print(int('$agC') // 3)")
xs "$C_PK" "$POOL" 'approve(address,uint256)' "$SP" "$half_C" >/dev/null
xs "$C_PK" "$SP" 'deposit(uint256,address)' "$half_C" "$C" >/dev/null
ok "deposited 150k → agYLD; staked 1/3 → sagYLD; ~100k agYLD remains in wallet"

# ─────────────────────────────────────────────────────────────────────
# Wallet D (WHALE_3) — safe borrower
# ─────────────────────────────────────────────────────────────────────
D_PK="$WHALE_3_PK"; D="$WHALE_3_ADDR"; D_LABEL="D WHALE_3  safe-borrower"

phase "$D_LABEL  $D"
xs "$PK" "$SRESOLV_TOKEN" 'mint(address,uint256)' "$D" 100000000000000000000000 >/dev/null
COL_D=50000000000000000000000  # 50k sRESOLV
DATA_D=$(cast abi-encode 'f(uint256)' $COL_D)
xs "$D_PK" "$POOL" 'openVaultPosition()' >/dev/null
xs "$D_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$COL_D" >/dev/null
xs "$D_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA_D" >/dev/null
# Borrow 5k USDr — collat value ~$50k @ LT 85% = $42.5k, so HF = 42.5/5 = 8.5
xs "$D_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 5000000000000000000000 >/dev/null
hf_D=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$SRESOLV_ADAPTER" "$D" "$ZERO")
ok "deposited 50k sRESOLV; borrowed 5k USDr; HF = $hf_D"

# ─────────────────────────────────────────────────────────────────────
# Wallet E (WHALE_4) — borderline borrower
# ─────────────────────────────────────────────────────────────────────
E_PK="$WHALE_4_PK"; E="$WHALE_4_ADDR"; E_LABEL="E WHALE_4  borderline-borrower"

phase "$E_LABEL  $E"
xs "$PK" "$JRESOLV_TOKEN" 'mint(address,uint256)' "$E" 100000000000000000000000 >/dev/null
COL_E=50000000000000000000000  # 50k jRESOLV
DATA_E=$(cast abi-encode 'f(uint256)' $COL_E)
xs "$E_PK" "$POOL" 'openVaultPosition()' >/dev/null
xs "$E_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$COL_E" >/dev/null
xs "$E_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA_E" >/dev/null
# jRESOLV LT=65%, max LTV=50%; collat $50k → max borrow $25k. Borrow $20k → HF = 32.5/20 = 1.625
xs "$E_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" 20000000000000000000000 >/dev/null
hf_E=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$JRESOLV_ADAPTER" "$E" "$ZERO")
ok "deposited 50k jRESOLV; borrowed 20k USDr; HF = $hf_E (BORDERLINE)"

# ─────────────────────────────────────────────────────────────────────
# Wallet F (MIDCAP_3) — cooldown-pending staker
# ─────────────────────────────────────────────────────────────────────
F_PK="$MIDCAP_3_PK"; F="$MIDCAP_3_ADDR"; F_LABEL="F MIDCAP_3 cooldown-pending"

phase "$F_LABEL  $F"
xs "$PK" "$USDR" 'mint(address,uint256)' "$F" 100000000000000000000000 >/dev/null
xs "$F_PK" "$USDR" 'approve(address,uint256)' "$POOL" 50000000000000000000000 >/dev/null
xs "$F_PK" "$POOL" 'deposit(uint256,address)' 50000000000000000000000 "$F" >/dev/null
agF=$(xc $POOL 'balanceOf(address)(uint256)' $F)
xs "$F_PK" "$POOL" 'approve(address,uint256)' "$SP" "$agF" >/dev/null
xs "$F_PK" "$SP" 'deposit(uint256,address)' "$agF" "$F" >/dev/null
sagF=$(xc $SP 'balanceOf(address)(uint256)' $F)
half_F=$(python3 -c "print(int('$sagF') // 2)")
xs "$F_PK" "$SP" 'requestUnstake(uint256)' "$half_F" >/dev/null
emF=$(xc $SP 'earmarkedShares(address)(uint256)' $F)
ok "deposited 50k → agYLD; staked all → sagYLD; requested half = earmarked $emF"

# ─────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────
phase "SUMMARY  — connect any of these wallets to the front"

readState() {
  local label="$1" addr="$2" pk="$3"
  local usdr=$(xc $USDR 'balanceOf(address)(uint256)' $addr)
  local agyld=$(xc $POOL 'balanceOf(address)(uint256)' $addr)
  local sagyld=$(xc $SP 'balanceOf(address)(uint256)' $addr)
  local debt=$(xc $DEBT 'balanceOf(address)(uint256)' $addr)
  local em=$(xc $SP 'earmarkedShares(address)(uint256)' $addr)
  echo ""
  printf "%s\n" "── $label"
  printf "  address:    %s\n" "$addr"
  printf "  pk:         %s\n" "$pk"
  printf "  USDr:       %s\n" "$(python3 -c "print(f'{int(\"$usdr\")/1e18:,.2f}')")"
  printf "  agYLD:      %s\n" "$(python3 -c "print(f'{int(\"$agyld\")/1e24:,.2f}')")"
  printf "  sagYLD:     %s\n" "$(python3 -c "print(f'{int(\"$sagyld\")/1e24:,.2f}')")"
  printf "  earmarked:  %s\n" "$(python3 -c "print(f'{int(\"$em\")/1e24:,.2f}')")"
  printf "  debt USDr:  %s\n" "$(python3 -c "print(f'{int(\"$debt\")/1e18:,.2f}')")"
}

readState "$A_LABEL" "$A" "$A_PK"
readState "$B_LABEL" "$B" "$B_PK"
readState "$C_LABEL" "$C" "$C_PK"
readState "$D_LABEL" "$D" "$D_PK"
readState "$E_LABEL" "$E" "$E_PK"
readState "$F_LABEL" "$F" "$F_PK"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  DONE — 6 wallets seeded with diverse on-chain states"
echo "════════════════════════════════════════════════════════"

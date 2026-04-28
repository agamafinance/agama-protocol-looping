#!/usr/bin/env bash
# Live Cat 3 — Repay. Picks 2 scenarios:
#   S3.1 — Partial repay 50% (uses MODERATE_0 / sCONDO; opens fresh pos)
#   S3.2 — Full repay + close vault on the same actor
source "$(dirname "$0")/_lib.sh"

section "Cat 3 LIVE — Repay"
send $PRIVATE_KEY $SCONDO_ORACLE 'setPrice(uint256)' $ONE

# Open a fresh moderate position on sCONDO so prior cats don't interfere.
section "Setup: MODERATE_0 borrows 50k on sCONDO"
COLLAT=100000000000000000000000  # 100k
SBORROW=50000000000000000000000  # 50k
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)
send "$MODERATE_0_PK" "$POOL" 'openVaultPosition()'
send "$MODERATE_0_PK" "$SCONDO_TOKEN" 'approve(address,uint256)' "$SCONDO_ADAPTER" "$COLLAT"
send "$MODERATE_0_PK" "$POOL" 'depositAsset(address,bytes)' "$SCONDO_ADAPTER" "$DATA"
send "$MODERATE_0_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO_BYTES" "$SBORROW"

PRE_DEBT=$(call $DEBT 'balanceOf(address)(uint256)' $MODERATE_0_ADDR | awk '{print $1}')
kv "MOD_0 debt pre" "$PRE_DEBT"

section "S3.1 — partial repay 50%"
HALF=$(python3 -c "print(int($PRE_DEBT) // 2)")
send "$MODERATE_0_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$HALF"
send "$MODERATE_0_PK" "$POOL" 'repay(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO_BYTES" "$HALF"
kv "MOD_0 debt mid" "$(call $DEBT 'balanceOf(address)(uint256)' $MODERATE_0_ADDR)"
kv "MOD_0 HF mid"   "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SCONDO_ADAPTER $MODERATE_0_ADDR $ZERO_BYTES)"
inv_check "POST-S3.1"

section "S3.2 — full repay + withdraw collateral"
REMAINING=$(call $DEBT 'balanceOf(address)(uint256)' $MODERATE_0_ADDR | awk '{print $1}')
# Add a buffer for any block-level interest accrued.
PADDED=$(python3 -c "print(int($REMAINING) * 101 // 100)")
send "$MODERATE_0_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$PADDED"
send "$MODERATE_0_PK" "$POOL" 'repay(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO_BYTES" "$REMAINING"
kv "MOD_0 debt post" "$(call $DEBT 'balanceOf(address)(uint256)' $MODERATE_0_ADDR)"

# Withdraw 100k collateral
send "$MODERATE_0_PK" "$POOL" 'withdrawAsset(address,bytes)' "$SCONDO_ADAPTER" "$DATA"
kv "MOD_0 collat post" "$(call $SCONDO_ADAPTER 'getAssetValue(address,bytes)(uint256)' $MODERATE_0_ADDR $ZERO_BYTES)"
inv_check "POST-S3.2"

section "Cat 3 LIVE done"

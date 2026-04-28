#!/usr/bin/env bash
# Live Cat 2 — Borrowing. Picks 3 scenarios:
#   S2.2 — Senior aggressive 74% LTV (sRESOLV)
#   S2.4 — Junior aggressive 49% LTV (jRESOLV)
#   S2.7 — Loop x2 Junior
source "$(dirname "$0")/_lib.sh"

section "Cat 2 LIVE — Borrowing"

# Reset Resolvi oracles to 1.0 just in case prior tests touched them.
send $PRIVATE_KEY $SRESOLV_ORACLE 'setPrice(uint256)' $ONE
send $PRIVATE_KEY $JRESOLV_ORACLE 'setPrice(uint256)' $ONE

inv_check "PRE"

section "S2.2 — Senior aggressive (74% LTV) on AGGRESSIVE_0 / sRESOLV"
COLLAT=100000000000000000000000  # 100k
SBORROW=74000000000000000000000  # 74k
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)
send "$AGGRESSIVE_0_PK" "$POOL" 'openVaultPosition()'
send "$AGGRESSIVE_0_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$COLLAT"
send "$AGGRESSIVE_0_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA"
send "$AGGRESSIVE_0_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO_BYTES" "$SBORROW"
kv "AGG_0 debt"  "$(call $DEBT 'balanceOf(address)(uint256)' $AGGRESSIVE_0_ADDR)"
kv "AGG_0 HF"    "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SRESOLV_ADAPTER $AGGRESSIVE_0_ADDR $ZERO_BYTES)"
inv_check "POST-S2.2"

section "S2.4 — Junior aggressive (49% LTV) on AGGRESSIVE_1 / jRESOLV"
JBORROW=49000000000000000000000  # 49k
send "$AGGRESSIVE_1_PK" "$POOL" 'openVaultPosition()'
send "$AGGRESSIVE_1_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$COLLAT"
send "$AGGRESSIVE_1_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA"
send "$AGGRESSIVE_1_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO_BYTES" "$JBORROW"
kv "AGG_1 debt"  "$(call $DEBT 'balanceOf(address)(uint256)' $AGGRESSIVE_1_ADDR)"
kv "AGG_1 HF"    "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $AGGRESSIVE_1_ADDR $ZERO_BYTES)"
inv_check "POST-S2.4"

section "S2.7 — Loop x2 Junior on AGGRESSIVE_2 / jRESOLV"
# Iter 1: 100k jRES, borrow 49k.
send "$AGGRESSIVE_2_PK" "$POOL" 'openVaultPosition()'
send "$AGGRESSIVE_2_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$COLLAT"
send "$AGGRESSIVE_2_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA"
send "$AGGRESSIVE_2_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO_BYTES" "$JBORROW"
# Iter 2: redeposit 49k jRES, borrow 24k.
LOOP_COL=49000000000000000000000  # 49k
LOOP_BORROW=24000000000000000000000  # 24k
LOOP_DATA=$(cast abi-encode 'f(uint256)' $LOOP_COL)
send "$AGGRESSIVE_2_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$LOOP_COL"
send "$AGGRESSIVE_2_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$LOOP_DATA"
send "$AGGRESSIVE_2_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO_BYTES" "$LOOP_BORROW"
kv "AGG_2 debt"  "$(call $DEBT 'balanceOf(address)(uint256)' $AGGRESSIVE_2_ADDR)"
kv "AGG_2 HF"    "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $AGGRESSIVE_2_ADDR $ZERO_BYTES)"
kv "AGG_2 collat value" "$(call $JRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $AGGRESSIVE_2_ADDR $ZERO_BYTES)"
inv_check "POST-S2.7"

section "Cat 2 LIVE done"

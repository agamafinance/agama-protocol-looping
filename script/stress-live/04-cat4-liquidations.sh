#!/usr/bin/env bash
# Live Cat 4 — Liquidations (the dramatic ones for the demo).
#   S4.1 — Single liquidation (jDIGCAP)
#   S4.3 — Cascade Junior 5 simultaneous (jCONDO)
#   S4.10 — Bonus distribution validation (settle one at face value)
source "$(dirname "$0")/_lib.sh"

section "Cat 4 LIVE — Liquidations"

# Reset oracles
send $PRIVATE_KEY $JDIGCAP_ORACLE 'setPrice(uint256)' $ONE
send $PRIVATE_KEY $JCONDO_ORACLE  'setPrice(uint256)' $ONE

# Need an SP staker first — CONSERVATIVE_0 lends 200k and stakes 100k USDr-eq.
section "Setup: CONSERVATIVE_0 -> LP 200k -> SP stake 100k USDr-eq"
LEND_AMT=200000000000000000000000
SP_STAKE=100000000000000000000000000000  # 100k USDr * 1e6 offset
send "$CONSERVATIVE_0_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$LEND_AMT"
send "$CONSERVATIVE_0_PK" "$POOL" 'deposit(uint256,address)' "$LEND_AMT" "$CONSERVATIVE_0_ADDR"
send "$CONSERVATIVE_0_PK" "$POOL" 'approve(address,uint256)' "$SP" "$SP_STAKE"
send "$CONSERVATIVE_0_PK" "$SP"   'deposit(uint256,address)' "$SP_STAKE" "$CONSERVATIVE_0_ADDR"

section "S4.1 — Single liquidation on AGGRESSIVE_3 / jDIGCAP"
COLLAT=100000000000000000000000
JBORROW=49000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)

send "$AGGRESSIVE_3_PK" "$POOL" 'openVaultPosition()'
send "$AGGRESSIVE_3_PK" "$JDIGCAP_TOKEN" 'approve(address,uint256)' "$JDIGCAP_ADAPTER" "$COLLAT"
send "$AGGRESSIVE_3_PK" "$POOL" 'depositAsset(address,bytes)' "$JDIGCAP_ADAPTER" "$DATA"
send "$AGGRESSIVE_3_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JDIGCAP_ADAPTER" "$ZERO_BYTES" "$JBORROW"

NEW=$(python3 -c "print(int($ONE) * 75 // 100)")
send $PRIVATE_KEY $JDIGCAP_ORACLE 'setPrice(uint256)' $NEW

kv "AGG_3 HF post-crash" "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JDIGCAP_ADAPTER $AGGRESSIVE_3_ADDR $ZERO_BYTES)"
send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' \
  $JDIGCAP_ADAPTER $JDIGCAP_ADAPTER $AGGRESSIVE_3_ADDR $ZERO_BYTES 0
kv "AGG_3 debt post-liq"  "$(call $DEBT 'balanceOf(address)(uint256)' $AGGRESSIVE_3_ADDR)"
kv "AGG_3 collat post-liq" "$(call $JDIGCAP_ADAPTER 'getAssetValue(address,bytes)(uint256)' $AGGRESSIVE_3_ADDR $ZERO_BYTES)"
inv_check "POST-S4.1"

section "S4.3 — Cascade Junior 5 simultaneous (jCONDO)"
SMALL_COL=50000000000000000000000   # 50k each
SMALL_BOR=24000000000000000000000   # 24k -> 48% LTV
SMALL_DATA=$(cast abi-encode 'f(uint256)' $SMALL_COL)

for i in 1 2 3 4; do
  pk_var="CONSERVATIVE_${i}_PK"
  addr_var="CONSERVATIVE_${i}_ADDR"
  pk="${!pk_var}"; addr="${!addr_var}"
  send "$pk" "$POOL" 'openVaultPosition()'
  send "$pk" "$JCONDO_TOKEN" 'approve(address,uint256)' "$JCONDO_ADAPTER" "$SMALL_COL"
  send "$pk" "$POOL" 'depositAsset(address,bytes)' "$JCONDO_ADAPTER" "$SMALL_DATA"
  send "$pk" "$POOL" 'borrow(address,bytes,uint256)' "$JCONDO_ADAPTER" "$ZERO_BYTES" "$SMALL_BOR"
done
# 5th: MODERATE_1
send "$MODERATE_1_PK" "$POOL" 'openVaultPosition()'
send "$MODERATE_1_PK" "$JCONDO_TOKEN" 'approve(address,uint256)' "$JCONDO_ADAPTER" "$SMALL_COL"
send "$MODERATE_1_PK" "$POOL" 'depositAsset(address,bytes)' "$JCONDO_ADAPTER" "$SMALL_DATA"
send "$MODERATE_1_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JCONDO_ADAPTER" "$ZERO_BYTES" "$SMALL_BOR"

# Crash jCONDO 65% -> HF = 0.65*35/24 = 0.948 -> LIQUIDATABLE
NEW=$(python3 -c "print(int($ONE) * 35 // 100)")
send $PRIVATE_KEY $JCONDO_ORACLE 'setPrice(uint256)' $NEW

for i in 1 2 3 4; do
  addr_var="CONSERVATIVE_${i}_ADDR"
  send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' \
    $JCONDO_ADAPTER $JCONDO_ADAPTER "${!addr_var}" $ZERO_BYTES 0
done
send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' \
  $JCONDO_ADAPTER $JCONDO_ADAPTER "$MODERATE_1_ADDR" $ZERO_BYTES 0

kv "Total debt post-cascade" "$(call $DEBT 'totalSupply()(uint256)')"
kv "jCONDO in SVault"        "$(call $JCONDO_TOKEN 'balanceOf(address)(uint256)' $SVAULT)"
inv_check "POST-S4.3"

section "S4.10 — Bonus distribution: settle batch 1 at face value 100k"
BATCH_ID=1
SETTLE=100000000000000000000000
send $PRIVATE_KEY $USDR 'mint(address,uint256)' $DEPLOYER $SETTLE
send $PRIVATE_KEY $USDR 'approve(address,uint256)' $SVAULT $SETTLE
send $PRIVATE_KEY $SVAULT 'settleRedemption(uint256,uint256)' $BATCH_ID $SETTLE
kv "pegGapPendingForSP" "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "SP price (1 share)"  "$(call $SP 'convertToAssets(uint256)(uint256)' $ONE)"
inv_check "POST-S4.10"

section "Cat 4 LIVE done"

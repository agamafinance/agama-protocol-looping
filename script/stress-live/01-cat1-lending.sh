#!/usr/bin/env bash
# Live Cat 1 — Lending. Picks 2 scenarios:
#   S1.1 — whales[0..2] deposit 100k / 80k / 60k
#   S1.4 — whale[0] partial withdraw 30k
source "$(dirname "$0")/_lib.sh"

section "Cat 1 LIVE — Lending"

inv_check "PRE"

# S1.1 live
section "S1.1 — 3 whales deposit (100k/80k/60k)"
for i in 0 1 2; do
  pk_var="WHALE_${i}_PK"
  addr_var="WHALE_${i}_ADDR"
  pk="${!pk_var}"; addr="${!addr_var}"
  amt_arr=(100000000000000000000000 80000000000000000000000 60000000000000000000000)
  amt="${amt_arr[$i]}"
  send "$pk" "$USDR" 'approve(address,uint256)' "$POOL" "$amt"
  send "$pk" "$POOL" 'deposit(uint256,address)' "$amt" "$addr"
  kv "WHALE_${i} agTOKEN" "$(call $POOL 'balanceOf(address)(uint256)' $addr)"
done
inv_check "POST-S1.1"

# S1.4 live
section "S1.4 — WHALE_0 partial withdraw 30k"
send "$WHALE_0_PK" "$POOL" 'withdraw(uint256,address,address)' \
  30000000000000000000000 "$WHALE_0_ADDR" "$WHALE_0_ADDR"
kv "WHALE_0 USDr post" "$(call $USDR 'balanceOf(address)(uint256)' $WHALE_0_ADDR)"
kv "WHALE_0 agTOKEN post" "$(call $POOL 'balanceOf(address)(uint256)' $WHALE_0_ADDR)"
inv_check "POST-S1.4"

section "Cat 1 LIVE done"

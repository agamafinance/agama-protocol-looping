#!/usr/bin/env bash
# Live Cat 5 — SP stake (one wallet stakes a meaningful amount; verifies
# RF + Treasury are also already on the SP from prior scenarios).
source "$(dirname "$0")/_lib.sh"

section "Cat 5 LIVE — SP stake"

# WHALE_3 lends 200k and stakes 150k USDr-eq.
LEND=200000000000000000000000
STAKE=150000000000000000000000000000  # 150k * 1e6
send "$WHALE_3_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$LEND"
send "$WHALE_3_PK" "$POOL" 'deposit(uint256,address)' "$LEND" "$WHALE_3_ADDR"
send "$WHALE_3_PK" "$POOL" 'approve(address,uint256)' "$SP" "$STAKE"
send "$WHALE_3_PK" "$SP"   'deposit(uint256,address)' "$STAKE" "$WHALE_3_ADDR"

kv "WHALE_3 agaSP" "$(call $SP 'balanceOf(address)(uint256)' $WHALE_3_ADDR)"
kv "Treasury agaSP" "$(call $SP 'balanceOf(address)(uint256)' $TREASURY)"
kv "RF agaSP"       "$(call $SP 'balanceOf(address)(uint256)' $RF)"
kv "SP totalSupply" "$(call $SP 'totalSupply()(uint256)')"
inv_check "POST"

section "Cat 5 LIVE done"

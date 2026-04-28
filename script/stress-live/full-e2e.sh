#!/usr/bin/env bash
# Full E2E flow on the FRESH 2026-04-28 redeploy.
#
# Walks through every user-facing action and asserts the on-chain state
# matches expectations at each step:
#   - Faucet: mint USDr + tranche tokens
#   - Earn deposit/withdraw: USDr -> agTOKEN at 1:1 baseline (1 USDr ->
#     1 agTOKEN human-readable, where agTOKEN has 24 decimals)
#   - Earn stake/redeem: agTOKEN -> agaSP, with the 24-decimal scale
#   - Borrow flow: open vault, deposit collateral, borrow, repay, withdraw
#   - Liquidation flow: crash oracle, proxy.liquidate, observe pegGap
#   - Settlement: manager settles batch at face value
#
# Every step prints the on-chain values (balances + decimals reasoning)
# so a reviewer can cross-check vs. what the front-end displays.

set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"

assert_eq() {
  # assert_eq label expected actual
  local label="$1"; local exp="$2"; local act="$3"
  if [ "$exp" = "$act" ]; then
    printf "  PASS   %-45s = %s\n" "$label" "$act"
  else
    printf "  FAIL   %-45s exp=%s act=%s\n" "$label" "$exp" "$act"
    exit 1
  fi
}
assert_approx() {
  # assert_approx label expected actual tolerance_wei
  local label="$1"; local exp="$2"; local act="$3"; local tol="$4"
  diff=$(python3 -c "print(abs(int('$exp') - int('$act')))")
  if [ "$(python3 -c "print(int('$diff') <= int('$tol'))")" = "True" ]; then
    printf "  PASS   %-45s = %s (within %s wei)\n" "$label" "$act" "$tol"
  else
    printf "  FAIL   %-45s exp~=%s act=%s diff=%s tol=%s\n" "$label" "$exp" "$act" "$diff" "$tol"
    exit 1
  fi
}

section "FULL E2E — fresh redeploy (deployer wallet only)"
kv "Deployer balance" "$(deployer_balance) USDr (gas)"

# ─────────────────────────────────────────────────────────────────────
# 1. FAUCET — mint via public mocks
# ─────────────────────────────────────────────────────────────────────
section "1. FAUCET — public mints to deployer"
MINT=1000000000000000000000000  # 1M tokens (1e6 * 1e18)
for tok in "$USDR" "$SRESOLV_TOKEN" "$JRESOLV_TOKEN" "$SDIGCAP_TOKEN" \
           "$JDIGCAP_TOKEN" "$SCONDO_TOKEN" "$JCONDO_TOKEN"; do
  send "$DEPLOYER_PK" "$tok" 'mint(address,uint256)' "$DEPLOYER" "$MINT"
done

# Check balances
USDR_BAL=$(call $USDR 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "USDr balance (1M, 18 dec)" "1000000000000000000000000" "$USDR_BAL"
SRES_BAL=$(call $SRESOLV_TOKEN 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "sRESOLV balance (1M, 18 dec)" "1000000000000000000000000" "$SRES_BAL"
JCON_BAL=$(call $JCONDO_TOKEN 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "jCONDO balance (1M, 18 dec)" "1000000000000000000000000" "$JCON_BAL"

# ─────────────────────────────────────────────────────────────────────
# 2. LP DEPOSIT — 100k USDr -> agTOKEN
# ─────────────────────────────────────────────────────────────────────
section "2. LP DEPOSIT — 100k USDr (24-dec agTOKEN check)"
DEPOSIT=100000000000000000000000  # 100k * 1e18
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$DEPOSIT"
send "$DEPLOYER_PK" "$POOL" 'deposit(uint256,address)' "$DEPOSIT" "$DEPLOYER"

AGTOKEN_BAL=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
LP_TA=$(call $POOL 'totalAssets()(uint256)' | awk '{print $1}')
LP_TS=$(call $POOL 'totalSupply()(uint256)' | awk '{print $1}')

# Expected: first deposit at 1:1 baseline with offset 6 -> 100k * 1e6 * 1e18 = 1e29 wei agTOKEN
# = 100,000 agTOKEN at 24 decimals.
assert_eq "agTOKEN balance (1e29 wei = 100k @ 24dec)" "100000000000000000000000000000" "$AGTOKEN_BAL"
assert_eq "LP totalAssets (100k USDr in wei)" "100000000000000000000000" "$LP_TA"
# Verify convertToAssets round-trips: 1e29 wei agTOKEN -> 1e23 wei USDr (with 1 wei rounding tolerance)
ROUNDTRIP=$(call $POOL 'convertToAssets(uint256)(uint256)' $AGTOKEN_BAL | awk '{print $1}')
assert_approx "convertToAssets(agTOKEN) -> USDr" "100000000000000000000000" "$ROUNDTRIP" "1"

# Verify pricePerShare display math: lpSharePrice = ta * 1e18 / ts, then * 1e6 for display.
# At 1:1 baseline this should yield 1e18 (= "1.000000 USDr / agTOKEN" in the UI).
LP_PPS_RAW=$(python3 -c "print(int('$LP_TA') * 10**18 // int('$LP_TS'))")
LP_PPS_DISPLAY=$(python3 -c "print(int('$LP_PPS_RAW') * 10**6)")
assert_eq "LP share price display (= 1e18 at baseline)" "1000000000000000000" "$LP_PPS_DISPLAY"

# ─────────────────────────────────────────────────────────────────────
# 3. LP WITHDRAW — 30k USDr back
# ─────────────────────────────────────────────────────────────────────
section "3. LP WITHDRAW — 30k USDr (test withdraw(assets))"
WITHDRAW=30000000000000000000000  # 30k * 1e18
USDR_PRE=$(call $USDR 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
send "$DEPLOYER_PK" "$POOL" 'withdraw(uint256,address,address)' "$WITHDRAW" "$DEPLOYER" "$DEPLOYER"
USDR_POST=$(call $USDR 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
DELTA=$(python3 -c "print(int('$USDR_POST') - int('$USDR_PRE'))")
assert_eq "USDr received (30k * 1e18)" "30000000000000000000000" "$DELTA"

# ─────────────────────────────────────────────────────────────────────
# 4. SP STAKE — stake half remaining agTOKEN
# ─────────────────────────────────────────────────────────────────────
section "4. SP STAKE — half remaining agTOKEN"
AGTOKEN_NOW=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
STAKE=$(python3 -c "print(int('$AGTOKEN_NOW') // 2)")
send "$DEPLOYER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$STAKE"
send "$DEPLOYER_PK" "$SP"   'deposit(uint256,address)' "$STAKE" "$DEPLOYER"

AGASP_BAL=$(call $SP 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
# At baseline (first SP deposit), agaSP minted = agTOKEN deposited (1:1, both 24-dec).
assert_eq "agaSP minted = agTOKEN staked" "$STAKE" "$AGASP_BAL"
SP_TA=$(call $SP 'totalAssets()(uint256)' | awk '{print $1}')
assert_eq "SP totalAssets = staked agTOKEN" "$STAKE" "$SP_TA"

# ─────────────────────────────────────────────────────────────────────
# 5. SP REDEEM — half the agaSP
# ─────────────────────────────────────────────────────────────────────
section "5. SP REDEEM — half agaSP back to agTOKEN"
REDEEM=$(python3 -c "print(int('$AGASP_BAL') // 2)")
AGTOKEN_PRE=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
# Need to advance a block (SP same-block guard) — send a no-op tx.
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$DEPLOYER" "0"
send "$DEPLOYER_PK" "$SP"   'redeem(uint256,address,address)' "$REDEEM" "$DEPLOYER" "$DEPLOYER"
AGTOKEN_POST=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
GOT=$(python3 -c "print(int('$AGTOKEN_POST') - int('$AGTOKEN_PRE'))")
assert_eq "agTOKEN returned = agaSP burned" "$REDEEM" "$GOT"

# ─────────────────────────────────────────────────────────────────────
# 6. BORROW FLOW — open vault, deposit collateral, borrow
# ─────────────────────────────────────────────────────────────────────
section "6. BORROW FLOW — sRESOLV collateral, borrow USDr"
COLLAT=10000000000000000000000   # 10k sRES
SBORROW=5000000000000000000000   # 5k USDr (50% LTV — well under 75% max)
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)

send "$DEPLOYER_PK" "$POOL" 'openVaultPosition()'
VAULT_OPEN=$(call $POOL 'vaultOpened(address)(bool)' $DEPLOYER | awk '{print $1}')
assert_eq "vaultOpened" "true" "$VAULT_OPEN"

send "$DEPLOYER_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$COLLAT"
send "$DEPLOYER_PK" "$POOL"          'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA"

COLLAT_VAL=$(call $SRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $DEPLOYER $ZERO_BYTES | awk '{print $1}')
assert_approx "sRESOLV collat value (10k USDr)" "10000000000000000000000" "$COLLAT_VAL" "1000000000000000"

send "$DEPLOYER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO_BYTES" "$SBORROW"
DEBT_BAL=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_approx "Debt = 5k USDr" "5000000000000000000000" "$DEBT_BAL" "100000000000000"
HF=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SRESOLV_ADAPTER $DEPLOYER $ZERO_BYTES | awk '{print $1}')
# HF = 0.85 * 10000 / 5000 * 1e27 = 1.7e27. Exact ratio should hold within RAY precision.
HF_EXPECTED="1700000000000000000000000000"
DIFF=$(python3 -c "print(abs(int('$HF') - int('$HF_EXPECTED')))")
PCT=$(python3 -c "print(int('$DIFF') * 10000 // int('$HF_EXPECTED'))")
if [ "$PCT" -le "10" ]; then
  printf "  PASS   %-45s = %s (HF~=1.7, drift %s bps)\n" "HF (LT 85% / debt 50%)" "$HF" "$PCT"
else
  printf "  FAIL   HF exp ~%s act=%s drift %s bps\n" "$HF_EXPECTED" "$HF" "$PCT"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# 7. REPAY + WITHDRAW COLLATERAL
# ─────────────────────────────────────────────────────────────────────
section "7. REPAY full + WITHDRAW collateral"
# Pay slightly more than outstanding to absorb any inter-block interest.
PAY=$(python3 -c "print(int(int('$DEBT_BAL') * 11) // 10)")  # 110% of debt
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$POOL" "$PAY"
# Use uint256.max so the LP only pulls what's actually owed.
send "$DEPLOYER_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO_BYTES" "115792089237316195423570985008687907853269984665640564039457584007913129639935"
DEBT_AFTER=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "Debt after full repay" "0" "$DEBT_AFTER"

send "$DEPLOYER_PK" "$POOL" 'withdrawAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA"
COLLAT_AFTER=$(call $SRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $DEPLOYER $ZERO_BYTES | awk '{print $1}')
assert_eq "Collateral fully withdrawn" "0" "$COLLAT_AFTER"

# ─────────────────────────────────────────────────────────────────────
# 8. LIQUIDATION FLOW — open jRESOLV pos, crash 25%, liquidate
# ─────────────────────────────────────────────────────────────────────
section "8. LIQUIDATION — jRESOLV at 49% LTV, 25% oracle drop"
COLLAT_J=10000000000000000000000      # 10k jRES
JBORROW=4900000000000000000000        # 4.9k USDr (49% LTV, max 50%)
DATA_J=$(cast abi-encode 'f(uint256)' $COLLAT_J)

send "$DEPLOYER_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$COLLAT_J"
send "$DEPLOYER_PK" "$POOL"          'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA_J"
send "$DEPLOYER_PK" "$POOL"          'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO_BYTES" "$JBORROW"
HF_PRE=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $DEPLOYER $ZERO_BYTES | awk '{print $1}')
kv "HF pre-crash" "$HF_PRE"

# Crash jRESOLV oracle 25%
send "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 750000000000000000  # 0.75 * 1e18
HF_POST=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $DEPLOYER $ZERO_BYTES | awk '{print $1}')
kv "HF post-crash 25%" "$HF_POST"
LIQ_THRESH=1000000000000000000000000000  # HF=1.0 in RAY
if [ "$(python3 -c "print(int('$HF_POST') < int('$LIQ_THRESH'))")" != "True" ]; then
  echo "  FAIL: position should be liquidatable post-crash"
  exit 1
fi
printf "  PASS   %-45s\n" "HF dropped below 1 — liquidatable"

# Liquidate via proxy
send "$DEPLOYER_PK" "$PROXY" 'liquidate(address,address,address,bytes,uint256)' \
  "$JRESOLV_ADAPTER" "$JRESOLV_ADAPTER" "$DEPLOYER" "$ZERO_BYTES" 0
DEBT_LIQ=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
assert_eq "Debt cleared after liquidation" "0" "$DEBT_LIQ"
COLLAT_LIQ=$(call $JRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $DEPLOYER $ZERO_BYTES | awk '{print $1}')
assert_eq "Collateral seized (0 left)" "0" "$COLLAT_LIQ"
SVAULT_JRES=$(call $JRESOLV_TOKEN 'balanceOf(address)(uint256)' $SVAULT | awk '{print $1}')
assert_eq "jRESOLV in SVault (10k seized)" "10000000000000000000000" "$SVAULT_JRES"
PEGGAP=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
# pegGap = absorbed debt ~= 4.9k USDr (with a tiny interest accrual)
assert_approx "pegGap pending (~4.9k USDr)" "4900000000000000000000" "$PEGGAP" "100000000000000000"

# ─────────────────────────────────────────────────────────────────────
# 9. SETTLEMENT — manager pays face value (10k USDr for 10k jRES)
# ─────────────────────────────────────────────────────────────────────
section "9. SETTLEMENT — manager pays 10k USDr face value"
BATCH_ID=$(call $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
SETTLE=10000000000000000000000  # 10k USDr
# Mint USDr to deployer to pay
send "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$SETTLE"
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$SVAULT" "$SETTLE"
send "$DEPLOYER_PK" "$SVAULT" 'settleRedemption(uint256,uint256)' "$BATCH_ID" "$SETTLE"
PEGGAP_POST=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
assert_eq "pegGap drained" "0" "$PEGGAP_POST"

# Restore jRESOLV oracle so the protocol stays usable
send "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 1000000000000000000

# ─────────────────────────────────────────────────────────────────────
# 10. FRONT-END SANITY — query the same values via the localhost RPC proxy
# ─────────────────────────────────────────────────────────────────────
section "10. FRONT — same reads via localhost /api/rpc"
URL=http://localhost:3000
# eth_chainId
CHAIN=$(curl -s -X POST "$URL/api/rpc" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
assert_eq "Front /api/rpc chainId (= 7295799)" "0x6f5337" "$CHAIN"

# LP totalAssets via proxy
TA_HEX=$(curl -s -X POST "$URL/api/rpc" -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$POOL\",\"data\":\"0x01e1d114\"},\"latest\"],\"id\":1}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
TA_PROXY=$(python3 -c "print(int('$TA_HEX', 16))")
TA_DIRECT=$(call $POOL 'totalAssets()(uint256)' | awk '{print $1}')
assert_eq "LP totalAssets matches (proxy vs direct)" "$TA_DIRECT" "$TA_PROXY"

section "FULL E2E — done"
echo "  All flows passed. Deployer ended with:"
echo "    USDr:    $(call $USDR 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')"
echo "    agTOKEN: $(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')"
echo "    agaSP:   $(call $SP   'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')"
echo "    Debt:    $(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')"
echo "  Native gas remaining: $(deployer_balance) USDr"

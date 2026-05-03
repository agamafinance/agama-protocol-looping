#!/usr/bin/env bash
# Multi-tranche E2E on V2 — multiple borrowers, multiple tranches,
# liquidation cascade, settlement, observe SP price pump.
set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"

assert_eq() {
  local label="$1"; local exp="$2"; local act="$3"
  if [ "$exp" = "$act" ]; then printf "  PASS   %-50s = %s\n" "$label" "$act"
  else printf "  FAIL   %-50s exp=%s act=%s\n" "$label" "$exp" "$act"; exit 1
  fi
}

ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

section "MULTI-TRANCHE E2E V2 — sRES borrower + jRES borrower + cascade"

# ─────────────────────────────────────────────────────────────────────
# 1. Mint sRESOLV + jRESOLV to deployer (we'll act as both borrowers)
# ─────────────────────────────────────────────────────────────────────
section "1. Mint 1M of each tranche to deployer"
MINT=1000000000000000000000000
for t in $SRESOLV_TOKEN $JRESOLV_TOKEN; do
  send "$DEPLOYER_PK" "$t" 'mint(address,uint256)' "$DEPLOYER" "$MINT"
done

# ─────────────────────────────────────────────────────────────────────
# 2. Open vault, deposit 100k sRES, borrow 60k USDr (LTV 60% < max 75%)
# ─────────────────────────────────────────────────────────────────────
section "2. sRES position: 100k collat, 60k borrow"
COLLAT=100000000000000000000000
SBORROW=60000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)
send "$DEPLOYER_PK" "$POOL" 'openVaultPosition()'
send "$DEPLOYER_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$COLLAT"
send "$DEPLOYER_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA"
send "$DEPLOYER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" "$SBORROW"
HF_S=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SRESOLV_ADAPTER $DEPLOYER $ZERO | awk '{print $1}')
echo "  HF sRES: $(python3 -c "print(int('$HF_S')/1e27)")"

# ─────────────────────────────────────────────────────────────────────
# 3. Add jRES collateral, borrow more
# ─────────────────────────────────────────────────────────────────────
section "3. Add jRES position: 100k collat, 30k extra borrow"
JBORROW=30000000000000000000000
send "$DEPLOYER_PK" "$JRESOLV_TOKEN" 'approve(address,uint256)' "$JRESOLV_ADAPTER" "$COLLAT"
send "$DEPLOYER_PK" "$POOL" 'depositAsset(address,bytes)' "$JRESOLV_ADAPTER" "$DATA"
send "$DEPLOYER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$JRESOLV_ADAPTER" "$ZERO" "$JBORROW"
DEBT_TOTAL=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
echo "  Total debt: $(python3 -c "print(int('$DEBT_TOTAL')/1e18)")  USDr (~90k)"
HF_S2=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SRESOLV_ADAPTER $DEPLOYER $ZERO | awk '{print $1}')
HF_J2=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $DEPLOYER $ZERO | awk '{print $1}')
echo "  HF sRES: $(python3 -c "print(int('$HF_S2')/1e27)")"
echo "  HF jRES: $(python3 -c "print(int('$HF_J2')/1e27)")"

# ─────────────────────────────────────────────────────────────────────
# 4. Crash jRES oracle 30% — pushes jRES HF below 1
# ─────────────────────────────────────────────────────────────────────
section "4. Crash jRESOLV oracle 30%"
NEW_PRICE=700000000000000000  # 0.7 USDr
send "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' "$NEW_PRICE"
HF_J3=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $DEPLOYER $ZERO | awk '{print $1}')
HF_J3_HUMAN=$(python3 -c "print(int('$HF_J3')/1e27)")
echo "  HF jRES post-crash: $HF_J3_HUMAN"
if [ "$(python3 -c "print(int('$HF_J3') < 10**27)")" = "True" ]; then
  echo "  PASS   jRES position is liquidatable (HF < 1)"
else
  echo "  FAIL   jRES not liquidatable"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# 5. Liquidate via jRES adapter
# ─────────────────────────────────────────────────────────────────────
section "5. Liquidate borrower on jRES adapter"
SP_TA_PRE=$(call $SP 'totalAssets()(uint256)' | awk '{print $1}')
send "$DEPLOYER_PK" "$PROXY" 'liquidate(address,address,address,bytes,uint256)' \
  "$JRESOLV_ADAPTER" "$JRESOLV_ADAPTER" "$DEPLOYER" "$ZERO" 0

DEBT_AFTER=$(call $DEBT 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
JRES_VAULT=$(call $JRESOLV_TOKEN 'balanceOf(address)(uint256)' $SVAULT | awk '{print $1}')
PEGGAP=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
echo "  Debt after liq: $(python3 -c "print(int('$DEBT_AFTER')/1e18)")  USDr"
echo "  jRES seized to SVault: $(python3 -c "print(int('$JRES_VAULT')/1e18)")"
echo "  pegGap pending: $(python3 -c "print(int('$PEGGAP')/1e18)") USDr"

# ─────────────────────────────────────────────────────────────────────
# 6. Settle redemption at face value
# ─────────────────────────────────────────────────────────────────────
section "6. Settle batch at face value (100k jRES = 100k USDr)"
BATCH=$(call $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
SETTLE=100000000000000000000000
send "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$SETTLE"
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$SVAULT" "$SETTLE"
send "$DEPLOYER_PK" "$SVAULT" 'settleRedemption(uint256,uint256)' "$BATCH" "$SETTLE"

PEGGAP_POST=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
SP_TA_POST=$(call $SP 'totalAssets()(uint256)' | awk '{print $1}')
assert_eq "pegGap drained" "0" "$PEGGAP_POST"

PRE_NUM=$(python3 -c "print(int('$SP_TA_PRE'))")
POST_NUM=$(python3 -c "print(int('$SP_TA_POST'))")
DIFF=$(python3 -c "print(int('$POST_NUM') - int('$PRE_NUM'))")
echo "  SP totalAssets pre :  $PRE_NUM"
echo "  SP totalAssets post:  $POST_NUM"
echo "  Bonus to SP (delta):  $(python3 -c "print(int('$DIFF')/1e24)")  agYLD"

if [ "$(python3 -c "print(int('$POST_NUM') >= int('$PRE_NUM'))")" = "True" ]; then
  echo "  PASS   SP totalAssets >= pre-liquidation (smoothing + bonus)"
else
  echo "  FAIL   SP totalAssets dropped"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# 7. Restore oracle to 1.0
# ─────────────────────────────────────────────────────────────────────
section "7. Restore jRES oracle to 1.0"
send "$DEPLOYER_PK" "$JRESOLV_ORACLE" 'setPrice(uint256)' 1000000000000000000

section "DONE"
echo "  Multi-tranche cascade + settlement validated end-to-end on V2."

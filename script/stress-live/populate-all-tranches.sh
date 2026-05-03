#!/usr/bin/env bash
# Populate the 4 unused tranches (sDIGCAP, jDIGCAP, sCONDO, jCONDO)
# so the Borrow page shows non-zero pool collat across all 6 markets.
# Uses 4 distinct borrower wallets so each market has its own actor.
# Notes: macOS bash 3 → no associative arrays, just inline params.
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }
phase(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }

# do_one  sym  pk  addr  token  adapter  collat_units  borrow_units
do_one() {
  local sym="$1" pk="$2" addr="$3" tok="$4" ad="$5" col="$6" bor="$7"
  local COL_WEI=$(python3 -c "print($col * 10**18)")
  local BORROW_WEI=$(python3 -c "print($bor * 10**18)")
  local DATA=$(cast abi-encode 'f(uint256)' $COL_WEI)

  phase "$sym  wallet=$addr  collat=${col}  borrow=${bor} USDr"
  xs "$PK"  "$tok"   'mint(address,uint256)'              "$addr" "$COL_WEI" >/dev/null
  ok "minted $col $sym"
  xs "$pk"  "$POOL"  'openVaultPosition()' >/dev/null
  xs "$pk"  "$tok"   'approve(address,uint256)'           "$ad"   "$COL_WEI" >/dev/null
  xs "$pk"  "$POOL"  'depositAsset(address,bytes)'        "$ad"   "$DATA" >/dev/null
  ok "deposited as collateral"
  xs "$pk"  "$POOL"  'borrow(address,bytes,uint256)'      "$ad"   "$ZERO" "$BORROW_WEI" >/dev/null
  local hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$ad" "$addr" "$ZERO")
  ok "borrowed $bor USDr; HF = $(python3 -c "print(int('$hf')/1e27)")"
}

echo "════════════════════════════════════════════════════════════"
echo "  Populate 4 unused tranches with collateral + debt"
echo "════════════════════════════════════════════════════════════"

#         sym       pk                       addr                       token              adapter            col      borrow
do_one sDIGCAP "$WHALE_2_PK"        "$WHALE_2_ADDR"        "$SDIGCAP_TOKEN" "$SDIGCAP_ADAPTER" 40000 4000
do_one jDIGCAP "$MIDCAP_4_PK"       "$MIDCAP_4_ADDR"       "$JDIGCAP_TOKEN" "$JDIGCAP_ADAPTER" 30000 8000
do_one sCONDO  "$CONSERVATIVE_2_PK" "$CONSERVATIVE_2_ADDR" "$SCONDO_TOKEN"  "$SCONDO_ADAPTER"  60000 15000
do_one jCONDO  "$CONSERVATIVE_3_PK" "$CONSERVATIVE_3_ADDR" "$JCONDO_TOKEN"  "$JCONDO_ADAPTER"  25000 8000

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Final state: pool collat per tranche"
echo "════════════════════════════════════════════════════════════"
for sym in sRESOLV jRESOLV sDIGCAP jDIGCAP sCONDO jCONDO; do
  tok=$(eval "echo \$${sym}_TOKEN")
  ad=$(eval "echo \$${sym}_ADAPTER")
  bal=$(xc $tok 'balanceOf(address)(uint256)' "$ad")
  bal_h=$(python3 -c "print(int('$bal')/1e18)")
  printf "  %-8s  %s\n" "$sym" "$bal_h"
done

debt_ts=$(xc $DEBT 'totalSupply()(uint256)')
echo ""
echo "  total debt: $(python3 -c "print(int('$debt_ts')/1e18)") USDr"

echo ""
echo "✓ DONE — all 6 tranches now have on-chain activity"

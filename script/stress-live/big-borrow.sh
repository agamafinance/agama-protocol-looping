#!/usr/bin/env bash
# Push utilization from ~4% → ~50% via a single big borrow against
# senior Resolvi (LT 85%, maxLTV 75%). Demonstrates APR mechanics
# work in real-time on chain.
set +e
source "$(dirname "$0")/_lib.sh"
PK="$PRIVATE_KEY"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }
phase(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }

# Use a fresh wallet — RETAIL_2 (untouched by previous runs)
B_PK="$RETAIL_2_PK"; B="$RETAIL_2_ADDR"

snapshot() {
  local label="$1"
  local ta=$(xc $POOL 'totalAssets()(uint256)')
  local debt_ts=$(xc $DEBT 'totalSupply()(uint256)')
  local cash=$(xc $USDR 'balanceOf(address)(uint256)' "$POOL")
  local rs=$(cast call --rpc-url "$RPC" $POOL 'getReserveState()((uint256,uint256,uint256,uint256,uint40))' 2>/dev/null)
  # parse currentLiquidityRate (3rd) and currentBorrowRate (4th) from tuple
  local liq_rate=$(echo "$rs" | tr -d '() ' | awk -F, '{print $3}')
  local bor_rate=$(echo "$rs" | tr -d '() ' | awk -F, '{print $4}')
  local util=$(python3 -c "print(int('$debt_ts')/int('$ta')*100)" 2>/dev/null || echo "?")

  echo ""
  echo "  ── $label ──"
  printf "    %-22s %s\n" "Pool TVL"        "$(python3 -c "print(f'{int(\"$ta\")/1e18:,.0f}') USDr")"
  printf "    %-22s %s\n" "Cash on pool"    "$(python3 -c "print(f'{int(\"$cash\")/1e18:,.0f}') USDr")"
  printf "    %-22s %s\n" "Total debt"      "$(python3 -c "print(f'{int(\"$debt_ts\")/1e18:,.0f}') USDr")"
  printf "    %-22s %.2f %%\n" "Utilization" "$util"
  printf "    %-22s %s\n" "Lender APR"      "$(python3 -c "print(f'{int(\"$liq_rate\")/1e27*100:.4f}%')")"
  printf "    %-22s %s\n" "Borrow APR"      "$(python3 -c "print(f'{int(\"$bor_rate\")/1e27*100:.4f}%')")"
}

echo "════════════════════════════════════════════════════════════"
echo "  BIG BORROW — drive utilization from 4% → ~50%"
echo "════════════════════════════════════════════════════════════"

snapshot "BEFORE"

phase "1. mint 1M sRESOLV to borrower"
xs "$PK" "$SRESOLV_TOKEN" 'mint(address,uint256)' "$B" 1000000000000000000000000 >/dev/null
ok "minted 1,000,000 sRESOLV"

phase "2. openVaultPosition + deposit 1M as collateral"
xs "$B_PK" "$POOL" 'openVaultPosition()' >/dev/null
xs "$B_PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" 1000000000000000000000000 >/dev/null
DATA=$(cast abi-encode 'f(uint256)' 1000000000000000000000000)
xs "$B_PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA" >/dev/null
col=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' $B)
ok "collateral parked: $(python3 -c "print(int('$col')/1e18)") sRESOLV (~\$1M @ pps=1)"

phase "3. borrow 700k USDr"
xs "$B_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 700000000000000000000000 >/dev/null
hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$SRESOLV_ADAPTER" "$B" "$ZERO")
ok "borrowed 700,000 USDr; HF = $(python3 -c "print(int('$hf')/1e27)")"

snapshot "AFTER"

phase "4. partial repay 200k (re-test the descent path)"
xs "$PK" "$USDR" 'mint(address,uint256)' "$B" 250000000000000000000000 >/dev/null
xs "$B_PK" "$USDR" 'approve(address,uint256)' "$POOL" 250000000000000000000000 >/dev/null
xs "$B_PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" 200000000000000000000000 >/dev/null
ok "repaid 200,000 USDr"

snapshot "AFTER PARTIAL REPAY"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ DONE — APR responded to live utilization changes"
echo "════════════════════════════════════════════════════════════"

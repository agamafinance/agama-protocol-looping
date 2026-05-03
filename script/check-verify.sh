#!/usr/bin/env bash
# Check Blockscout verification status for every deployed contract.
set +e
BS=https://testnet-explorer.rayls.com/api/v2/smart-contracts

VERIFIED=0
UNVERIFIED=0
declare -a UNVERIFIED_LIST

check() {
  local name="$1" addr="$2"
  local resp=$(curl -s -o /dev/null -w "%{http_code}" "$BS/$addr")
  if [ "$resp" = "200" ]; then
    local body=$(curl -s "$BS/$addr")
    local is=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('is_verified', False))" 2>/dev/null)
    if [ "$is" = "True" ]; then
      printf "  ✓ %-25s %s\n" "$name" "$addr"
      VERIFIED=$((VERIFIED + 1))
    else
      printf "  ✗ %-25s %s\n" "$name" "$addr"
      UNVERIFIED=$((UNVERIFIED + 1))
      UNVERIFIED_LIST+=("$name $addr")
    fi
  else
    printf "  ? %-25s %s (HTTP %s)\n" "$name" "$addr" "$resp"
    UNVERIFIED=$((UNVERIFIED + 1))
    UNVERIFIED_LIST+=("$name $addr")
  fi
}

echo "=== Main contracts ==="
for k in USDr MockAMFI MockOracle Faucet SplitFaucet LendingPool DebtToken AmFiAdapter StabilityPool LiquidationProxy SettlementVault Treasury ReserveFund FeeCollector; do
  addr=$(jq -r ".contracts.$k" deployments/7295799.json)
  check "$k" "$addr"
done

echo ""
echo "=== Tranches ==="
for sym in sRESOLV jRESOLV sDIGCAP jDIGCAP sCONDO jCONDO; do
  for kind in token oracle adapter; do
    addr=$(jq -r ".$sym.$kind" deployments/7295799.tranches.json)
    check "${sym}_${kind}" "$addr"
  done
done

echo ""
echo "=== TOTAL ==="
echo "Verified:   $VERIFIED"
echo "Unverified: $UNVERIFIED"
if [ $UNVERIFIED -gt 0 ]; then
  echo "Missing:"
  for u in "${UNVERIFIED_LIST[@]}"; do echo "  $u"; done
fi

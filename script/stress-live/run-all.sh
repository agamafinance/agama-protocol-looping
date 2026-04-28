#!/usr/bin/env bash
# Stress test orchestrator. Runs every live cat script in order, captures
# per-cat logs into $STRESS_RESULTS_DIR, then finalizes the markdown reports.
#
# Pre-requisite: 00-setup-wallets.sh has already been executed and
# $STRESS_RESULTS_DIR is set (or will be auto-created).

set -e
cd "$(dirname "$0")/../.."

if [ -z "$STRESS_RESULTS_DIR" ]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  export STRESS_RESULTS_DIR="$(pwd)/stress-test-results/$TS"
  mkdir -p "$STRESS_RESULTS_DIR"
  echo "Auto-created STRESS_RESULTS_DIR=$STRESS_RESULTS_DIR"
fi

# Capture deployer balance pre-test for gas accounting.
source .env
export STRESS_DEPLOYER_PRE=$(cast balance --ether --rpc-url "$RAYLS_TESTNET_RPC" \
  0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16 | awk '{print $1}')
echo "STRESS_DEPLOYER_PRE=$STRESS_DEPLOYER_PRE USDr"

run_cat() {
  local id="$1"; local script="$2"
  echo ""
  echo "=== Running $script ==="
  bash "$script" 2>&1 | tee "$STRESS_RESULTS_DIR/$id.log" | tail -40
}

run_cat 01 script/stress-live/01-cat1-lending.sh
run_cat 02 script/stress-live/02-cat2-borrowing.sh
run_cat 03 script/stress-live/03-cat3-repay.sh
run_cat 04 script/stress-live/04-cat4-liquidations.sh
run_cat 05 script/stress-live/05-cat7-oracle-flash.sh
run_cat 06 script/stress-live/06-cat5-sp-stake.sh

bash script/stress-live/99-finalize-report.sh

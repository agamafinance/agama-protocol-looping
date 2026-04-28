#!/usr/bin/env bash
# Shared lib for stress-live scripts. Sourced by every cat script.
# Usage: source script/stress-live/_lib.sh

set -e
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source .env
source script/stress-live/keys.env

# ---- Live deployment (FRESH redeploy 2026-04-28) ----
export DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
export USDR=0x4C10ee20C0CC7e81B162fE488d1C8b7514cb45Fe
export POOL=0x251716FeAf75B834d1431060C28E345D4EF45Ed3
export DEBT=0xe4B39BA721c8186CFb553c3700ADFeB76DB5Bb4b
export SP=0x617127857cb16Ed219e849e6b61E671ca2aF1834
export PROXY=0xa138ADc46A6378400A4E8FD499B250b29F3451A2
export SVAULT=0x400c32594087e07050B4487978209a748536715f
export TREASURY=0x32d735bc48F33164ADe5AA961698df81891caC0b
export RF=0x4772dbF6F1a329722BAA27320B2e1488A18575b9

# Tranches (FRESH delta deploy 2026-04-28)
export SRESOLV_TOKEN=0xB881bC67D8ABc087abcE24b2DC3D4eEB90011cD6
export SRESOLV_ORACLE=0x838ca078a5dFe530fb13C0d2A0C140F0F7C5bD2C
export SRESOLV_ADAPTER=0xee6477802aF51D1B1fD1ed7C730692E09FDCC114

export JRESOLV_TOKEN=0x8aB8310447d0C31d28B7262DCe85A99BABa5b122
export JRESOLV_ORACLE=0x6d81E10796Cc75ed828269f7b6Ec3C3a745849BF
export JRESOLV_ADAPTER=0x202353aada2df66406828f3B0dF009Bba9162d90

export SDIGCAP_TOKEN=0xa9cf7508E81e5DE7600cD57e68fB332Cb10679be
export SDIGCAP_ORACLE=0x3f762F5A86aee068c444311643905eF17828BC04
export SDIGCAP_ADAPTER=0xB03D1BD1062A8431A5Bb4d19354fB69053647dEe

export JDIGCAP_TOKEN=0xf3d838b244A78e5C5e96932F433f46486f52c18A
export JDIGCAP_ORACLE=0xE4766A9f14f85fb5302C76d8760d96B8Fe7072B9
export JDIGCAP_ADAPTER=0x94ad2bF7B3793DF9967c66F76233CE39f0d1562d

export SCONDO_TOKEN=0x0d76Fe81db40212eC1dB79a86C8DB5eBAa0217f6
export SCONDO_ORACLE=0x4E67B4c1E923F080572aA85352d2A69FD5a9bf3e
export SCONDO_ADAPTER=0xcCD46637247C88D54dBA922D9A9B685e11A65a21

export JCONDO_TOKEN=0xdd66d8C4b3f26Db7D4a0AF6749a93027b933eB0b
export JCONDO_ORACLE=0x2E59B0BdC077fc6D9DF503B2e6a11bF87F65223d
export JCONDO_ADAPTER=0xaf0Eb58A92c33499d6A7824C1894EA9651780A1c

export RPC="$RAYLS_TESTNET_RPC"
export ZERO_BYTES=$(cast abi-encode 'f(uint256)' 0)
export ONE=1000000000000000000  # 1e18

section() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
kv()      { printf "  %-44s %s\n" "$1" "$2"; }
call()    { cast call --rpc-url "$RPC" "$@"; }
send()    {
  local pk="$1"; shift
  cast send --rpc-url "$RPC" --private-key "$pk" "$@" 2>&1 | grep -E '^(status|Error|Context)' | head -3
}

# Track lifetime native gas spent in this run for the gas budget report.
GAS_LOG="${STRESS_RESULTS_DIR:-/tmp}/gas-budget.txt"
mkdir -p "$(dirname "$GAS_LOG")"
note_gas() {
  local label="$1"; local amount="$2"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $label  $amount" >> "$GAS_LOG"
}

deployer_balance() {
  cast balance --ether --rpc-url "$RPC" "$DEPLOYER"
}

# ---- Invariant checks (live) -------------------------------------------
inv_check() {
  local label="$1"
  local cash=$(call $USDR 'balanceOf(address)(uint256)' $POOL | awk '{print $1}')
  local debtSupply=$(call $DEBT 'totalSupply()(uint256)' | awk '{print $1}')
  local lpAssets=$(call $POOL 'totalAssets()(uint256)' | awk '{print $1}')
  local diff=$(python3 -c "print(int('$lpAssets') - int('$cash') - int('$debtSupply'))")
  printf "  INV1[%s] cash=%s debt=%s ta=%s diff=%s\n" "$label" "$cash" "$debtSupply" "$lpAssets" "$diff"
}

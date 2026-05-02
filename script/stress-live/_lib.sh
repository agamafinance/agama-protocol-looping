#!/usr/bin/env bash
# Shared lib for stress-live scripts. Sourced by every cat script.
# Usage: source script/stress-live/_lib.sh

set -e
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source .env
source script/stress-live/keys.env

# ---- Live deployment (V2 cooldown SP — 2026-05-03) ----
export DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
export USDR=0x00aF00B730ce56041A2932621128D1c582C9d0a8
export POOL=0x9087c6aB946E31A32D9f01b28F521AE18919935F
export DEBT=0xCeda381F9A6e12F2987aC6733074D8E31491FFCc
export SP=0x25D024B16044Ff3c7F49f63bB6431f205E2B0D3A
export PROXY=0x61A45741c42D96095C3534D61B171ff98bcA63A0
export SVAULT=0x4066d0565ADC898e564760024B5b57eeA62cd74a
export TREASURY=0x526D5F9b33ED9608d466aA7b9996E635c80E7b0c
export RF=0x7e92622baE6D7099f610e8D32ffb2f9069e661Fd

# Tranches (V2 delta deploy 2026-05-03)
export SRESOLV_TOKEN=0x73f6941325Bde3fc59eBC74C5418e3fA3C971Ba7
export SRESOLV_ORACLE=0x45fa8182A5acc4B0132267F826de05096E03cc15
export SRESOLV_ADAPTER=0x7B61bD652DF46FfB8390dE2a012C56E9cf1a1115

export JRESOLV_TOKEN=0xB81707f4ba65BD2080F48fb196D9Adb8b0d2729a
export JRESOLV_ORACLE=0x0881de1E7E6C037A9Bce2928b1ae5b35a3627b59
export JRESOLV_ADAPTER=0x07C92C8D4ac9A0aaF9Ed9f95fd9fBd8f46D41508

export SDIGCAP_TOKEN=0x3C300F75fBE858fCA923db10E3d38d06839b9B44
export SDIGCAP_ORACLE=0xB23f43F9507EAAb680c3118cf2E75f7396eB98E5
export SDIGCAP_ADAPTER=0x344A7B5BD59A377313377F3d154b48c1b3512162

export JDIGCAP_TOKEN=0x7845D018Cda36B360b9B313335Fd87974207e176
export JDIGCAP_ORACLE=0x04ADF345a7562C090066EfFA2543bFAB2Fce9eF0
export JDIGCAP_ADAPTER=0x0f57038B52DD4203b3c7f89105d91A96500E5fD0

export SCONDO_TOKEN=0xDaF1046093B8E82C2B31e8225158fca9A1Bed7b6
export SCONDO_ORACLE=0xacDde978bcF73647c274839BEC68B30b821C6bCD
export SCONDO_ADAPTER=0xE69aa2Cad0620B86b9bF4Ec7ca060C47dF2BE65d

export JCONDO_TOKEN=0xFF589c2c8BA5E171F2ae8c4f6A82C80A2c5B220D
export JCONDO_ORACLE=0x90E629Ea3D395BD18E617E37a594D325eCB9C864
export JCONDO_ADAPTER=0xd23b4783996A4Db45BC54F05985aB0B90E06DAe9

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

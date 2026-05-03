#!/usr/bin/env bash
# Shared lib for stress-live scripts. Sourced by every cat script.
# Usage: source script/stress-live/_lib.sh

set -e
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source .env
source script/stress-live/keys.env

# ---- Live deployment (V2 cooldown SP — 2026-05-03) ----
export DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
export USDR=0x3E7C9256CdA8aa079f360a9f15A52D003912a936
export POOL=0x33608779D60B608e316C0B731d874EFa208cbD1d
export DEBT=0xEA10aaDECE23527e26C353b7490797127cc40Bd6
export SP=0x1E158df48170753B286A0Afd70Dc6E92e9bcDf6C
export PROXY=0x5491A2EF1D1FE9E2a09fe6CC85AF835d780Aa5C4
export SVAULT=0xd6d431fB35e6821C541422784EA4E5DE604a15a6
export TREASURY=0x9C32D5797Cc6Ea924dBd6393250dCF28A7AFD165
export RF=0x7A1d13a6770A1729ae70826156ae7826fC7b30EB

# Tranches (V2 delta deploy 2026-05-03)
export SRESOLV_TOKEN=0x87B050a6a3f1dB8A276EcaE3b5214639FfD9b657
export SRESOLV_ORACLE=0xc7b23e987Dfb8fB6Af226982dc65239087Cc3D20
export SRESOLV_ADAPTER=0x9eb5AB72CE6A46F92d6a1750Dc8287cB05A94692

export JRESOLV_TOKEN=0xB4B1CE855bCAD4E3B5Fdcc1EAC7EE3714D638AAf
export JRESOLV_ORACLE=0x77Bd525F8F3c8D59125AeC6d09a5FaB7A854b291
export JRESOLV_ADAPTER=0xeDB3B2e962Aa51823c47632f1440cFE078fe143d

export SDIGCAP_TOKEN=0xB6a4316eAa6071d4302181a3Dfc25742dcDc345F
export SDIGCAP_ORACLE=0x4Df85Deac96f65d809024023906c65F07C105633
export SDIGCAP_ADAPTER=0xD767f54533c79CE262A92fcC60e917a27E432398

export JDIGCAP_TOKEN=0xE12C445C0B508F12596667405eEd937630b270fF
export JDIGCAP_ORACLE=0x92bf4901965dD3d7fAADf709585864612c428d0D
export JDIGCAP_ADAPTER=0x7652e1a7CB213445ade0E9Ae5370276f873e7153

export SCONDO_TOKEN=0x0a3ecf2bA64222916c6D3Af9C32CB0778712DFE4
export SCONDO_ORACLE=0x08CA1654ec931d42DaF90a42Ca4c1bad9B328E4E
export SCONDO_ADAPTER=0x24148e83F12763BE9F27069448E6df8d5D88445A

export JCONDO_TOKEN=0x5D2d57a53EE34544812BE6081e9F47E204159231
export JCONDO_ORACLE=0x82a1FD798584B2aa0Aaf1085A7ecc48493D1236a
export JCONDO_ADAPTER=0x2351feA32d9f05787524A5cB0A0f879a16A9c045

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

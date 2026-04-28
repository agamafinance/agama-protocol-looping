#!/usr/bin/env bash
# Shared lib for stress-live scripts. Sourced by every cat script.
# Usage: source script/stress-live/_lib.sh

set -e
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source .env
source script/stress-live/keys.env

# ---- Live deployment (cascade redeploy 2026-04-27 + Phase-3 tranches) ----
export DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
export USDR=0x14800741698994a5fa46ac83c232bF6079CdD316
export POOL=0xeeA0D4A279C19B02c27c34a6daB3f20a9A7E2253
export DEBT=0xF6467F72138ACA31bD2cCE8D65aA684144d88755
export SP=0x32De79544A1BF5d0b4914F7Ff9626C0CEfdd5B44
export PROXY=0x479d2b5067fe95BFbA1356DfC4E35E7404E07962
export SVAULT=0x9524F26f5E2537b16844A9fB5787853BD990E3A3
export TREASURY=0xF5735b4E7Bd9cc56955A4B7e9Eddc28005A5A242
export RF=0x8bF3d0CeE013DE8750b07C0C803EE088dA5e2516

# Tranches (Phase-3 delta deploy)
export SRESOLV_TOKEN=0x890e59f727E14B4d57888f29efa0d81d311ec784
export SRESOLV_ORACLE=0xDF0dFfE36C06106cfd734BCdbA002d8A31F98d98
export SRESOLV_ADAPTER=0x7fe22e656d190e166fC853d1067f2d510D4F62cc

export JRESOLV_TOKEN=0x66b7D55ceDB0b7ADda648d66FC60Ae354bD6C5f8
export JRESOLV_ORACLE=0x92f4c22CC1eA2eAa4C2514f3bEfD659FaE5C78F6
export JRESOLV_ADAPTER=0x7a68aB5f4Bc6c7dd4EE44CE0e0b517174067F08D

export SDIGCAP_TOKEN=0x35EE4bbD3b57684b2Cdc26881b77b13018C42cD4
export SDIGCAP_ORACLE=0x6C5F83E13006F59158E6daE263806113B23b1d2D
export SDIGCAP_ADAPTER=0x7C81A56dCdca65c14296F7aaCE852634A5C85512

export JDIGCAP_TOKEN=0x901AfE1322CA6fF34e48c6A2A5699bce43ad5b6F
export JDIGCAP_ORACLE=0xBA3176283bB2b7Eb5E3bDF53030C93c0105Bb0f0
export JDIGCAP_ADAPTER=0x5B7e6fD986DA5aDB6FA4446788d9Ef0b17767dfA

export SCONDO_TOKEN=0x7D13cCE5c0AF8517eF51c193Cb6C3cDaFfe965Bd
export SCONDO_ORACLE=0xe430e5148083c4bA9B961f7A23CFBC542151aA72
export SCONDO_ADAPTER=0xF7922C0471b0e3E6716Fc4d245a5ACad3f1686F8

export JCONDO_TOKEN=0x24f6B0B78097A8D494eFcE7c804603097677202D
export JCONDO_ORACLE=0x03d4F51cCc31f5aF0d36776E53CdFa9afcA09030
export JCONDO_ADAPTER=0xf5eFefbE6ecC0D1B1720473e9643642b12dB98F7

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

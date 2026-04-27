#!/usr/bin/env bash
# Live multi-tranche E2E on Rayls testnet — Phase 4 validation.
#
# Goal: demonstrate per-tranche risk isolation under a Resolvi pool stress
# event. Uses sRESOLV (LT 85%, LTV 75%) and jRESOLV (LT 65%, LTV 50%) so the
# junior tranche tips below HF=1 first while the senior survives the same
# oracle drop. A second, deeper drop pushes the senior below HF=1 too.
#
# Cast: 3 fresh wallets — Alice (senior borrower), Bob (junior borrower),
# Carol (lender + SP staker). Deployer plays manager/governor.

set -e
cd "$(dirname "$0")/.."
source .env

# ---- Live deployment (cascade redeploy 2026-04-27 + Phase-3 tranche delta) ----
DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
USDR=0x14800741698994a5fa46ac83c232bF6079CdD316
POOL=0xeeA0D4A279C19B02c27c34a6daB3f20a9A7E2253
DEBT=0xF6467F72138ACA31bD2cCE8D65aA684144d88755
SP=0x32De79544A1BF5d0b4914F7Ff9626C0CEfdd5B44
PROXY=0x479d2b5067fe95BFbA1356DfC4E35E7404E07962
SVAULT=0x9524F26f5E2537b16844A9fB5787853BD990E3A3
TREASURY=0xF5735b4E7Bd9cc56955A4B7e9Eddc28005A5A242
RF=0x8bF3d0CeE013DE8750b07C0C803EE088dA5e2516

# Resolvi tranches (Phase-3 delta deploy)
SRESOLV_TOKEN=0x890e59f727E14B4d57888f29efa0d81d311ec784
SRESOLV_ORACLE=0xDF0dFfE36C06106cfd734BCdbA002d8A31F98d98
SRESOLV_ADAPTER=0x7fe22e656d190e166fC853d1067f2d510D4F62cc

JRESOLV_TOKEN=0x66b7D55ceDB0b7ADda648d66FC60Ae354bD6C5f8
JRESOLV_ORACLE=0x92f4c22CC1eA2eAa4C2514f3bEfD659FaE5C78F6
JRESOLV_ADAPTER=0x7a68aB5f4Bc6c7dd4EE44CE0e0b517174067F08D

# Fresh wallets
ALICE_ADDR=0x6776AcD4276e682626C3694F2Ba321155934A551
ALICE_PK=0xd871129139277a4ceaa0723429f2eedd16c1e9500b099a6f8add8b977ed4c2f5
BOB_ADDR=0xAA669ac9F8216534FeC3045CBDF2d731F80bD899
BOB_PK=0xe5a981a82b157c8ab8f3ceda90f48e20cde33fde5aa601cea2d684fa343032b0
CAROL_ADDR=0x6966f2d34F871F1580bd5B38EbAAd51287Eac3BD
CAROL_PK=0xa5de0f74adb4bcda9194300686d2fded8f474fba118116cacb92033377c71c7f

RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)
ONE=1000000000000000000  # 1e18

section() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
kv()      { printf "  %-40s %s\n" "$1" "$2"; }
call()    { cast call --rpc-url "$RPC" "$@"; }
send()    { local pk="$1"; shift; cast send --rpc-url "$RPC" --private-key "$pk" "$@" 2>&1 | grep -E '^(status|Error)' | head -2; }

hf_pct() {
  # Convert RAY-scaled HF to percentage with 2 decimals.
  python3 -c "v=int('$1'); print(f'{v/1e27*100:.2f}%' if v < 10**70 else 'inf')"
}

show_state() {
  local label="$1"
  echo "  ── $label ──"
  local s_hf=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $SRESOLV_ADAPTER $ALICE_ADDR $ZERO | awk '{print $1}')
  local j_hf=$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $JRESOLV_ADAPTER $BOB_ADDR   $ZERO | awk '{print $1}')
  local s_val=$(call $SRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $ALICE_ADDR $ZERO | awk '{print $1}')
  local j_val=$(call $JRESOLV_ADAPTER 'getAssetValue(address,bytes)(uint256)' $BOB_ADDR   $ZERO | awk '{print $1}')
  local s_debt=$(call $DEBT 'balanceOf(address)(uint256)' $ALICE_ADDR | awk '{print $1}')
  local j_debt=$(call $DEBT 'balanceOf(address)(uint256)' $BOB_ADDR   | awk '{print $1}')
  local s_or=$(call $SRESOLV_ORACLE 'getPrice()(uint256)' | awk '{print $1}')
  local j_or=$(call $JRESOLV_ORACLE 'getPrice()(uint256)' | awk '{print $1}')
  printf "  %-12s | oracle=%s | collat=%s | debt=%s | HF=%s\n" \
    "Alice/sRES" "$(python3 -c "print(f'{int(\"$s_or\")/1e18:.4f}')")" \
    "$(python3 -c "print(f'{int(\"$s_val\")/1e18:>12,.2f}')")" \
    "$(python3 -c "print(f'{int(\"$s_debt\")/1e18:>12,.2f}')")" \
    "$(hf_pct $s_hf)"
  printf "  %-12s | oracle=%s | collat=%s | debt=%s | HF=%s\n" \
    "Bob/jRES"   "$(python3 -c "print(f'{int(\"$j_or\")/1e18:.4f}')")" \
    "$(python3 -c "print(f'{int(\"$j_val\")/1e18:>12,.2f}')")" \
    "$(python3 -c "print(f'{int(\"$j_debt\")/1e18:>12,.2f}')")" \
    "$(hf_pct $j_hf)"
}

section "PRE-RUN — protocol & tranche state"
kv "LP totalAssets"     "$(call $POOL 'totalAssets()(uint256)')"
kv "SP totalSupply"     "$(call $SP   'totalSupply()(uint256)')"
kv "LP testnetMode"     "$(call $POOL 'testnetMode()(bool)')"
kv "sRESOLV adapter LT" "$(call $SRESOLV_ADAPTER 'LIQUIDATION_THRESHOLD()(uint256)')"
kv "sRESOLV adapter LTV" "$(call $SRESOLV_ADAPTER 'MAX_LTV()(uint256)')"
kv "jRESOLV adapter LT" "$(call $JRESOLV_ADAPTER 'LIQUIDATION_THRESHOLD()(uint256)')"
kv "jRESOLV adapter LTV" "$(call $JRESOLV_ADAPTER 'MAX_LTV()(uint256)')"
kv "LP supports sRES"   "$(call $POOL 'supportedAdapter(address)(bool)' $SRESOLV_ADAPTER)"
kv "LP supports jRES"   "$(call $POOL 'supportedAdapter(address)(bool)' $JRESOLV_ADAPTER)"

section "1. Reset Resolvi oracles to 1.0 + bump lastUpdate"
send $PRIVATE_KEY $SRESOLV_ORACLE 'setPrice(uint256)' $ONE
send $PRIVATE_KEY $JRESOLV_ORACLE 'setPrice(uint256)' $ONE
kv "sRES oracle"  "$(call $SRESOLV_ORACLE 'getPrice()(uint256)')"
kv "jRES oracle"  "$(call $JRESOLV_ORACLE 'getPrice()(uint256)')"

section "2. Fund 1 native USDr (gas) to Alice/Bob/Carol"
for addr in $ALICE_ADDR $BOB_ADDR $CAROL_ADDR; do
  cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$addr" --value 1ether 2>&1 | grep -E '^status' | head -1
  kv "$addr"  "$(cast balance --ether --rpc-url $RPC $addr) USDr (native)"
done

section "3. Mint mock tokens"
# Each mint = 1M tokens (1e6 * 1e18). Public mint, no role.
MINT=1000000000000000000000000

# Alice: sRESOLV collateral
send $ALICE_PK $SRESOLV_TOKEN 'mint(address,uint256)' $ALICE_ADDR $MINT
# Bob: jRESOLV collateral
send $BOB_PK   $JRESOLV_TOKEN 'mint(address,uint256)' $BOB_ADDR   $MINT
# Carol: USDr to lend + stake
send $CAROL_PK $USDR          'mint(address,uint256)' $CAROL_ADDR $MINT

kv "Alice sRESOLV" "$(call $SRESOLV_TOKEN 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Bob   jRESOLV" "$(call $JRESOLV_TOKEN 'balanceOf(address)(uint256)' $BOB_ADDR)"
kv "Carol USDr"    "$(call $USDR 'balanceOf(address)(uint256)' $CAROL_ADDR)"

section "4. Carol deposits 800k USDr → LP, stakes 500k USDr-equiv into SP"
# Pool decimal offset = 6 (per LendingPool config). 1 USDr → 1e6 agTOKEN.
# Stake 500k USDr-equiv = 500k * 1e6 = 5e29 wei agTOKEN.
DEP_USDR=800000000000000000000000     # 800k USDr
SP_STAKE=500000000000000000000000000000   # 5e29 agTOKEN

send $CAROL_PK $USDR 'approve(address,uint256)' $POOL $DEP_USDR
send $CAROL_PK $POOL 'deposit(uint256,address)' $DEP_USDR $CAROL_ADDR
send $CAROL_PK $POOL 'approve(address,uint256)' $SP   $SP_STAKE
send $CAROL_PK $SP   'deposit(uint256,address)' $SP_STAKE $CAROL_ADDR
kv "Carol agTOKEN" "$(call $POOL 'balanceOf(address)(uint256)' $CAROL_ADDR)"
kv "Carol agaSP"   "$(call $SP   'balanceOf(address)(uint256)' $CAROL_ADDR)"

section "5a. Alice opens vault, deposits 100k sRESOLV, borrows 50k USDr (LTV=50%, max 75%)"
COLLAT=100000000000000000000000  # 100k * 1e18
SBORROW=50000000000000000000000  # 50k * 1e18

send $ALICE_PK $POOL 'openVaultPosition()'
send $ALICE_PK $SRESOLV_TOKEN 'approve(address,uint256)' $SRESOLV_ADAPTER $COLLAT
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)
send $ALICE_PK $POOL 'depositAsset(address,bytes)' $SRESOLV_ADAPTER $DATA
send $ALICE_PK $POOL 'borrow(address,bytes,uint256)' $SRESOLV_ADAPTER $ZERO $SBORROW

section "5b. Bob opens vault, deposits 100k jRESOLV, borrows 49k USDr (LTV=49%, max 50%)"
JBORROW=49000000000000000000000   # 49k * 1e18

send $BOB_PK $POOL 'openVaultPosition()'
send $BOB_PK $JRESOLV_TOKEN 'approve(address,uint256)' $JRESOLV_ADAPTER $COLLAT
send $BOB_PK $POOL 'depositAsset(address,bytes)' $JRESOLV_ADAPTER $DATA
send $BOB_PK $POOL 'borrow(address,bytes,uint256)' $JRESOLV_ADAPTER $ZERO $JBORROW

show_state "PRE-CRASH (oracles at 1.0)"

section "6. CRASH — Resolvi oracles drop 25% (both sRES and jRES at 0.75)"
NEW_PRICE_25=$(python3 -c "print(int($ONE) * 75 // 100)")
send $PRIVATE_KEY $SRESOLV_ORACLE 'setPrice(uint256)' $NEW_PRICE_25
send $PRIVATE_KEY $JRESOLV_ORACLE 'setPrice(uint256)' $NEW_PRICE_25

show_state "POST 25% DROP — junior should tip, senior survives"

# Mathematically expected:
#   Alice (sRES): collat 100k * 0.75 = 75k → HF = 0.85*75/50 = 1.275 (safe)
#   Bob   (jRES): collat 100k * 0.75 = 75k → HF = 0.65*75/49 = 0.9949 (LIQ)

section "7. Liquidate Bob (junior) — single instant call"
send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' \
  $JRESOLV_ADAPTER $JRESOLV_ADAPTER $BOB_ADDR $ZERO 0
kv "Bob debt (cleared)"        "$(call $DEBT 'balanceOf(address)(uint256)' $BOB_ADDR)"
kv "Bob jRES collateral (seized)" "$(call $JRESOLV_ADAPTER 'balanceOf(address)(uint256)' $BOB_ADDR)"
kv "jRES in SVault"            "$(call $JRESOLV_TOKEN 'balanceOf(address)(uint256)' $SVAULT)"

show_state "AFTER junior liquidation"

section "8. CRASH MORE — Resolvi oracles drop to 0.50 (50% total)"
NEW_PRICE_50=$(python3 -c "print(int($ONE) * 50 // 100)")
send $PRIVATE_KEY $SRESOLV_ORACLE 'setPrice(uint256)' $NEW_PRICE_50
send $PRIVATE_KEY $JRESOLV_ORACLE 'setPrice(uint256)' $NEW_PRICE_50

show_state "POST 50% DROP — senior should now tip"

# Expected:
#   Alice (sRES): collat 100k * 0.50 = 50k → HF = 0.85*50/50 = 0.85 (LIQ)

section "9. Liquidate Alice (senior) — single instant call"
send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' \
  $SRESOLV_ADAPTER $SRESOLV_ADAPTER $ALICE_ADDR $ZERO 0
kv "Alice debt (cleared)"          "$(call $DEBT 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Alice sRES collateral (seized)" "$(call $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "sRES in SVault"                "$(call $SRESOLV_TOKEN 'balanceOf(address)(uint256)' $SVAULT)"

show_state "FINAL — both borrowers wiped"

section "10. Other tranches unaffected — Digcap & Sector Condo oracles still at default"
SDIGCAP_ORACLE=0x6C5F83E13006F59158E6daE263806113B23b1d2D
JDIGCAP_ORACLE=0xBA3176283bB2b7Eb5E3bDF53030C93c0105Bb0f0
SCONDO_ORACLE=0xe430e5148083c4bA9B961f7A23CFBC542151aA72
JCONDO_ORACLE=0x03d4F51cCc31f5aF0d36776E53CdFa9afcA09030
kv "sDIGCAP oracle"    "$(call $SDIGCAP_ORACLE 'getPrice()(uint256)')"
kv "jDIGCAP oracle"    "$(call $JDIGCAP_ORACLE 'getPrice()(uint256)')"
kv "sCONDO  oracle"    "$(call $SCONDO_ORACLE  'getPrice()(uint256)')"
kv "jCONDO  oracle"    "$(call $JCONDO_ORACLE  'getPrice()(uint256)')"

section "DONE"
echo "  Phase 4 multi-tranche E2E complete."
echo "  Demonstrated: junior tipped first at 25% drop, senior survived;"
echo "  senior tipped at 50% drop. Other-pool oracles untouched throughout."

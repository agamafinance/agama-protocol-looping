#!/usr/bin/env bash
# Live E2E v3 on Rayls testnet — V1 4-decision refactor validation.
#
# Differences vs v2:
#   - No grace-period setter (instant liquidation: HF < 1 → fire).
#   - No SP timelock setter (direct ERC-4626 redeem).
#   - Single proxy.liquidate(...) call (no initiate, no sleep, no finalize).
#   - Demonstrates direct sp.redeem after the bonus stream lands.
#
# Cast: 3 fresh wallets (Doris, Eve, Frank) + deployer-as-manager.

set -e
cd "$(dirname "$0")/.."
source .env

# ---- Live deployment (cascade redeploy 2026-04-27, public mocks + Phase A-D) ----
DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
USDR=0x14800741698994a5fa46ac83c232bF6079CdD316
AMFI=0xAd677C70cDef8D3247A059C962cD26e56eDeC370
ORACLE=0xc5B4a178042013252cbC253135325b62802cc683
FAUCET=0xC387Ac278C62655AD38EdAd73aE75A254913884B
SPLIT=0xc81801c87128Eb7691B1CdA53C18a6a6AE911d2b
POOL=0xeeA0D4A279C19B02c27c34a6daB3f20a9A7E2253
DEBT=0xF6467F72138ACA31bD2cCE8D65aA684144d88755
ADAPTER=0xfbAF52f46ED8E529289f1e6c90B7735c2756f007
SP=0x32De79544A1BF5d0b4914F7Ff9626C0CEfdd5B44
PROXY=0x479d2b5067fe95BFbA1356DfC4E35E7404E07962
SVAULT=0x9524F26f5E2537b16844A9fB5787853BD990E3A3
TREASURY=0xF5735b4E7Bd9cc56955A4B7e9Eddc28005A5A242
RF=0x8bF3d0CeE013DE8750b07C0C803EE088dA5e2516

# Fresh wallets
DORIS_ADDR=0x677765784A2672a909749760aC8F8DbBB0e39620
DORIS_PK=0xc2d06d91c4d9dc435b85d8f24c842fcaefacec7e644766b429327918477fa4bc
EVE_ADDR=0x1Ba83f519D4b5C5D7515164fbe9BFF9Cf82c4d85
EVE_PK=0x1c0111e7f2d8eb033bb42961a7f5728da04993da0a56131a6df5b1fdd337f05f
FRANK_ADDR=0xE5e55134aE3E7312a7376945ec3ee4d6797b1c9C
FRANK_PK=0xf98e99d0a14b91f3869c4034d4690243d2f3c1e62372e6c9b7bdf7e71f7290ff

RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)
section() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
kv() { printf "  %-32s %s\n" "$1" "$2"; }
call() { cast call --rpc-url "$RPC" "$@"; }
send() { local pk="$1"; shift; cast send --rpc-url "$RPC" --private-key "$pk" "$@" 2>&1 | grep -E '^(status|Error)' | head -2; }

section "PRE-RUN — protocol-wide state"
kv "LP totalAssets" "$(call $POOL 'totalAssets()(uint256)')"
kv "SP totalAssets" "$(call $SP   'totalAssets()(uint256)')"
kv "SP totalSupply" "$(call $SP   'totalSupply()(uint256)')"
kv "Treasury agaSP" "$(call $SP   'balanceOf(address)(uint256)' $TREASURY)"
kv "RF agaSP"       "$(call $SP   'balanceOf(address)(uint256)' $RF)"
kv "SVault pegGap"  "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "Oracle"         "$(call $ORACLE 'getPrice()(uint256)')"
kv "LP testnetMode" "$(call $POOL 'testnetMode()(bool)')"

section "1. Restore oracle to 1.0 + bump lastUpdate"
send $PRIVATE_KEY $ORACLE 'setPrice(uint256)' 1000000000000000000
kv "Oracle now"         "$(call $ORACLE 'getPrice()(uint256)')"
kv "Oracle lastUpdate"  "$(call $ORACLE 'lastUpdate()(uint256)')"

section "2. Fund 1 native USDr (gas) to each new wallet"
for addr in $DORIS_ADDR $EVE_ADDR $FRANK_ADDR; do
  cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$addr" --value 1ether 2>&1 | grep -E '^status' | head -1
  kv "$addr" "$(cast balance --ether --rpc-url $RPC $addr) USDr"
done

section "3. Faucet drip from each wallet (USDr + AMFI)"
for pk in $DORIS_PK $EVE_PK $FRANK_PK; do
  send $pk $FAUCET 'drip()'
done

section "4. Doris deposits 800k USDr → stakes 500k in SP (× 1e6 offset)"
# With LP._decimalsOffset = 6: 1 USDr → 1e6 agTOKEN. So staking 500k USDr-
# equivalent agTOKEN means 500k * 1e6 = 5e29 wei agTOKEN.
send $DORIS_PK $USDR 'approve(address,uint256)' $POOL 800000000000000000000000
send $DORIS_PK $POOL 'deposit(uint256,address)' 800000000000000000000000 $DORIS_ADDR
send $DORIS_PK $POOL 'approve(address,uint256)' $SP 500000000000000000000000000000
send $DORIS_PK $SP   'deposit(uint256,address)' 500000000000000000000000000000 $DORIS_ADDR
kv "Doris agTOKEN" "$(call $POOL 'balanceOf(address)(uint256)' $DORIS_ADDR)"
kv "Doris agaSP"   "$(call $SP   'balanceOf(address)(uint256)' $DORIS_ADDR)"

section "5. Frank deposits 400k USDr (lender, no SP stake)"
send $FRANK_PK $USDR 'approve(address,uint256)' $POOL 400000000000000000000000
send $FRANK_PK $POOL 'deposit(uint256,address)' 400000000000000000000000 $FRANK_ADDR
kv "Frank agTOKEN"  "$(call $POOL 'balanceOf(address)(uint256)' $FRANK_ADDR)"
kv "Frank agaSP"    "$(call $SP   'balanceOf(address)(uint256)' $FRANK_ADDR)"

section "6. Eve borrows at 70% LTV (max) — 700k AMFI, 490k USDr"
send $EVE_PK $POOL 'openVaultPosition()'
send $EVE_PK $AMFI 'approve(address,uint256)' $ADAPTER 700000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' 700000000000000000000000)
send $EVE_PK $POOL 'depositAsset(address,bytes)' $ADAPTER $DATA
send $EVE_PK $POOL 'borrow(address,bytes,uint256)' $ADAPTER $ZERO 490000000000000000000000

kv "Eve received USDr" "$(call $USDR 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve debt"          "$(call $DEBT 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve HF"            "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $EVE_ADDR $ZERO)"

section "7. fastForwardInterest(180 days) — debt grows ~3.5%"
send $PRIVATE_KEY $POOL 'fastForwardInterest(uint256)' 15552000
kv "Eve debt"  "$(call $DEBT 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve HF"    "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $EVE_ADDR $ZERO)"

section "8. Oracle crashes 25% — Eve under-collateralized"
PRICE=$(call $ORACLE 'getPrice()(uint256)' | awk '{print $1}')
NEW_PRICE=$(python3 -c "print(int($PRICE) * 75 // 100)")
send $PRIVATE_KEY $ORACLE 'setPrice(uint256)' $NEW_PRICE
kv "Oracle now" "$NEW_PRICE"
kv "Eve HF"     "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $EVE_ADDR $ZERO)"

section "9. SP price snapshot before liquidation"
SP_PRICE_PRE=$(call $SP 'convertToAssets(uint256)(uint256)' 1000000000000000000 | awk '{print $1}')
kv "SP share price" "$SP_PRICE_PRE"

section "10. INSTANT liquidation — single call, no grace, no sleep"
send $PRIVATE_KEY $PROXY 'liquidate(address,address,address,bytes,uint256)' $ADAPTER $ADAPTER $EVE_ADDR $ZERO 0

section "  POST-LIQUIDATION"
kv "Eve debt"           "$(call $DEBT 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve collateral"     "$(call $ADAPTER 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "AMFI in SVault"     "$(call $AMFI 'balanceOf(address)(uint256)' $SVAULT)"
kv "SVault pegGap"      "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "SP price (smoothed)" "$(call $SP 'convertToAssets(uint256)(uint256)' 1000000000000000000)"

section "11. Settle redemption with 115% return → bonus stream"
PEG_GAP=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
LATEST_BATCH=$(call $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
SETTLE_AMOUNT=$(python3 -c "print(int($PEG_GAP) * 115 // 100)")
kv "Latest batch"  "$LATEST_BATCH"
kv "Pegged gap"    "$PEG_GAP"
kv "Settling with" "$SETTLE_AMOUNT (115%)"

send $PRIVATE_KEY $USDR 'mint(address,uint256)' $DEPLOYER $SETTLE_AMOUNT
send $PRIVATE_KEY $USDR 'approve(address,uint256)' $SVAULT $SETTLE_AMOUNT
send $PRIVATE_KEY $SVAULT 'settleRedemption(uint256,uint256)' $LATEST_BATCH $SETTLE_AMOUNT

section "  POST-SETTLE"
kv "SVault pegGap"  "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "SP price post"  "$(call $SP 'convertToAssets(uint256)(uint256)' 1000000000000000000)"

section "12. Pro-rata earn — every agaSP holder pumped"
echo ""
echo "  Holder           USDr-equivalent (agaSP+agTOKEN combined)"
echo "  ───────────────  ──────────────────────────────────────────"
for pair in "RF:$RF" "Treasury:$TREASURY" "Doris:$DORIS_ADDR" "Frank-(no SP):$FRANK_ADDR"; do
  label="${pair%%:*}"; addr="${pair##*:}"
  agasp=$(call $SP 'balanceOf(address)(uint256)' $addr | awk '{print $1}')
  agtoken=$(call $POOL 'balanceOf(address)(uint256)' $addr | awk '{print $1}')
  if [ "$agasp" = "0" ] && [ "$agtoken" = "0" ]; then continue; fi
  agasp_usdr="0"
  if [ "$agasp" != "0" ]; then
    spv=$(call $SP   'convertToAssets(uint256)(uint256)' $agasp | awk '{print $1}')
    agasp_usdr=$(call $POOL 'convertToAssets(uint256)(uint256)' $spv | awk '{print $1}')
  fi
  agtoken_usdr="0"
  if [ "$agtoken" != "0" ]; then
    agtoken_usdr=$(call $POOL 'convertToAssets(uint256)(uint256)' $agtoken | awk '{print $1}')
  fi
  total=$(python3 -c "print(int(\"$agasp_usdr\") + int(\"$agtoken_usdr\"))")
  printf "  %-15s  %s\n" "$label" "$(python3 -c "print(f'{int(\"$total\")/1e18:>20,.4f} USDr')")"
done

section "13. Direct SP redeem (no timelock) — Doris pulls 100k agaSP-equiv (× 1e6)"
DORIS_AGASP_BEFORE=$(call $SP 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
DORIS_AGTOKEN_BEFORE=$(call $POOL 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
# 100k USDr-equivalent agaSP = 100_000e18 * 1e6 = 1e29 wei
send $DORIS_PK $SP 'redeem(uint256,address,address)' 100000000000000000000000000000 $DORIS_ADDR $DORIS_ADDR
DORIS_AGASP_AFTER=$(call $SP 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
DORIS_AGTOKEN_AFTER=$(call $POOL 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
kv "Doris agaSP burned"     "$(python3 -c "print(int($DORIS_AGASP_BEFORE) - int($DORIS_AGASP_AFTER))")"
kv "Doris agTOKEN received" "$(python3 -c "print(int($DORIS_AGTOKEN_AFTER) - int($DORIS_AGTOKEN_BEFORE))")"

section "14. Eve final state — borrower wiped"
kv "Eve USDr (kept the borrow proceeds)" "$(call $USDR 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve debt (cleared)"                  "$(call $DEBT 'balanceOf(address)(uint256)' $EVE_ADDR)"
kv "Eve collateral (seized)"             "$(call $ADAPTER 'balanceOf(address)(uint256)' $EVE_ADDR)"

section "DONE"
echo "V1 multi-actor E2E v3 complete. SP share price = $(call $SP 'convertToAssets(uint256)(uint256)' 1000000000000000000)"

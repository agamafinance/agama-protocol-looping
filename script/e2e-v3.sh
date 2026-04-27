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

# ---- Live deployment (post-refactor 2026-04-26) --------------------------
DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
USDR=0xe52958da496cc0D3A0c652692112D5519d3bBC63
AMFI=0xf2Db2114b62157D96a383f57De2221F8A5C00f7F
ORACLE=0x534eC51fd74405433e1388a2907b1949BfD89D2e
FAUCET=0x381C1F1153a1cacB8151c1e1c82E401F8E633C6d
POOL=0x2f712E6588C54dD995295B7e34411779CcC0075e
DEBT=0x884Cb0e601748e359B18B4c0CDafcE9E428948AF
ADAPTER=0xF9dC483AcB3000000c5fA8F9577BCb20bC473466
SP=0x48C5d92d50AcD644CCFAf931b98E86542Ef3B7A3
PROXY=0x30A7321FA55904B270729d515A6D95B4AcEB9A18
SVAULT=0x4920426C0F298B3f9B92073193Afa4cc7Ec85442
TREASURY=0x31eD9f328213a9e515bfa970BD745D67093Dc610
RF=0x96B233d79CC2C4011FC7C93697A186369B38B853

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

section "4. Doris deposits 800k USDr → stakes 500k in SP"
send $DORIS_PK $USDR 'approve(address,uint256)' $POOL 800000000000000000000000
send $DORIS_PK $POOL 'deposit(uint256,address)' 800000000000000000000000 $DORIS_ADDR
send $DORIS_PK $POOL 'approve(address,uint256)' $SP 500000000000000000000000
send $DORIS_PK $SP   'deposit(uint256,address)' 500000000000000000000000 $DORIS_ADDR
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

section "13. Direct SP redeem (no timelock) — Doris pulls 100k agaSP"
DORIS_AGASP_BEFORE=$(call $SP 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
DORIS_AGTOKEN_BEFORE=$(call $POOL 'balanceOf(address)(uint256)' $DORIS_ADDR | awk '{print $1}')
send $DORIS_PK $SP 'redeem(uint256,address,address)' 100000000000000000000000 $DORIS_ADDR $DORIS_ADDR
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

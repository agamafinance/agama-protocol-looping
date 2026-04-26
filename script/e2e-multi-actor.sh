#!/usr/bin/env bash
# Live multi-actor E2E on Rayls testnet (chain 7295799).
# See header in v1 for the scenario description.

set -e
cd "$(dirname "$0")/.."
source .env

# ---- Live deployment ---------------------------------------------------
DEPLOYER=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
USDR=0xF2e739F9cA47b075CB836511A65bAf353DDFe067
AMFI=0x78e0AB3F406E7FF1929623e0C344993d93873361
ORACLE=0x8cD52AF147Caf8EeC24f0111a86C440DD33FB330
FAUCET=0x520D9c689B575F823BB9E2211C4559ff6280D4fE
POOL=0x92D96b8cC443B81fBBB8a32358FD445Dd8488973
DEBT=0x163BA7E3750d86046eb12F66802D1073451c1f1E
ADAPTER=0x40CB409DE1f7F81CeBFdaf26053fff44018Df91b
SP=0x6B454ACEC8B621F62B6447b94003Aa2dD44dC440
PROXY=0xfe6De4e644019d68357d8A23f08B4FAfB119e84F
SVAULT=0xF0062D959B82541b811f79599536D35447CC7e75
TREASURY=0x23cCA7B1E4b2afB651CFBcfb0AC6cEB3259770d8
RF=0x53c71f7520E4f389a85b586a4E638B26F106EA46

# Fresh test wallets — testnet only
ALICE_ADDR=0x8Fb4205801ba1234702dA28FBc387351Fa39aa3B
ALICE_PK=0xa560bb92517f725b85e9baa3b74a776e4bfcfbcb4de9253725225a32e5449ea7
BOB_ADDR=0x324D0582FC88E64058de82128A27CaB369dB8b78
BOB_PK=0x3a67b76c0800f7458326a07d37b3abb0c45842f118fb7b163ac6899b1ba5d44a
CHARLIE_ADDR=0x063a9192c9E94BED6e991CdD268d5991dcdbf3E2
CHARLIE_PK=0xaa9323e6f30f4768c7f292c0868dda7945a4ad7e5db281099aeaeada6d0b6d5d

RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)
section() { echo ""; echo "════════════════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════════════════"; }
kv() { printf "  %-32s %s\n" "$1" "$2"; }
status() { echo "$1" | grep -E '^status' | head -1; }

call() { cast call --rpc-url "$RPC" "$@"; }
send() { local pk="$1"; shift; cast send --rpc-url "$RPC" --private-key "$pk" "$@" 2>&1 | grep -E '^(status|Error)' | head -2; }

section "0. Demo timings — admin compresses grace / timelocks to 5s"
send $PRIVATE_KEY $POOL 'setLiquidationGracePeriod(uint256)' 5
send $PRIVATE_KEY $SP   'setWithdrawTimelockDuration(uint256)' 5
kv "LP gracePeriod" "$(call $POOL 'liquidationGracePeriod()(uint256)')"
kv "SP timelockDur" "$(call $SP   'withdrawTimelockDuration()(uint256)')"

section "1. Fund each test wallet with 1 native USDr (gas)"
for addr in $ALICE_ADDR $BOB_ADDR $CHARLIE_ADDR; do
  cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$addr" --value 1ether 2>&1 | grep -E '^status' | head -1
  kv "$addr" "$(cast balance --ether --rpc-url $RPC $addr) USDr"
done

section "2. Each wallet drips USDr+AMFI from the faucet"
for pk in $ALICE_PK $BOB_PK $CHARLIE_PK; do
  send $pk $FAUCET 'drip()'
done
kv "Alice USDr" "$(call $USDR 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Bob USDr"   "$(call $USDR 'balanceOf(address)(uint256)' $BOB_ADDR)"
kv "Charlie USDr" "$(call $USDR 'balanceOf(address)(uint256)' $CHARLIE_ADDR)"

section "3. Bob deposits 1M USDr → stakes 600k agTOKEN in SP"
send $BOB_PK $USDR 'approve(address,uint256)' $POOL 1000000000000000000000000
send $BOB_PK $POOL 'deposit(uint256,address)' 1000000000000000000000000 $BOB_ADDR
send $BOB_PK $POOL 'approve(address,uint256)' $SP 600000000000000000000000
send $BOB_PK $SP 'deposit(uint256,address)' 600000000000000000000000 $BOB_ADDR
kv "Bob agTOKEN" "$(call $POOL 'balanceOf(address)(uint256)' $BOB_ADDR)"
kv "Bob agaSP"   "$(call $SP   'balanceOf(address)(uint256)' $BOB_ADDR)"

section "4. Charlie deposits 500k USDr → stakes 300k agTOKEN"
send $CHARLIE_PK $USDR 'approve(address,uint256)' $POOL 500000000000000000000000
send $CHARLIE_PK $POOL 'deposit(uint256,address)' 500000000000000000000000 $CHARLIE_ADDR
send $CHARLIE_PK $POOL 'approve(address,uint256)' $SP 300000000000000000000000
send $CHARLIE_PK $SP 'deposit(uint256,address)' 300000000000000000000000 $CHARLIE_ADDR
kv "Charlie agTOKEN" "$(call $POOL 'balanceOf(address)(uint256)' $CHARLIE_ADDR)"
kv "Charlie agaSP"   "$(call $SP   'balanceOf(address)(uint256)' $CHARLIE_ADDR)"

section "  POST-LENDER state"
kv "LP totalAssets" "$(call $POOL 'totalAssets()(uint256)')"
kv "SP totalAssets" "$(call $SP   'totalAssets()(uint256)')"
kv "SP totalSupply" "$(call $SP   'totalSupply()(uint256)')"

section "5. Alice borrows at 70% LTV — openVault + 500k AMFI + borrow 350k USDr"
send $ALICE_PK $POOL 'openVaultPosition()'
send $ALICE_PK $AMFI 'approve(address,uint256)' $ADAPTER 500000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' 500000000000000000000000)
send $ALICE_PK $POOL 'depositAsset(address,bytes)' $ADAPTER $DATA
send $ALICE_PK $POOL 'borrow(address,bytes,uint256)' $ADAPTER $ZERO 350000000000000000000000

kv "Alice USDr (post-borrow)" "$(call $USDR 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Alice debt"               "$(call $DEBT 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Alice HF"                 "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $ALICE_ADDR $ZERO)"

section "6. fastForwardInterest(90 days) — debt grows visibly"
send $PRIVATE_KEY $POOL 'fastForwardInterest(uint256)' 7776000
kv "Alice debt (post-fwd)"  "$(call $DEBT 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Alice HF   (post-fwd)"  "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $ALICE_ADDR $ZERO)"
kv "LP usageIndex"          "$(call $POOL 'getNormalizedDebt()(uint256)')"
kv "LP liquidityIndex"      "$(call $POOL 'getNormalizedIncome()(uint256)')"

section "7. Oracle crashes 30% — Alice's HF tips below 1"
PRICE=$(call $ORACLE 'getPrice()(uint256)' | awk '{print $1}')
NEW_PRICE=$(python3 -c "print(int($PRICE) * 70 // 100)")
send $PRIVATE_KEY $ORACLE 'setPrice(uint256)' $NEW_PRICE
kv "Oracle (was)" "$PRICE"
kv "Oracle (now)" "$NEW_PRICE"
kv "Alice HF"     "$(call $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' $ADAPTER $ALICE_ADDR $ZERO)"

section "8. Manager initiates → grace 5s → finalizes liquidation"
LP_PRICE_BEFORE=$(call $POOL 'convertToAssets(uint256)' 1000000000000000000)
SP_PRICE_BEFORE=$(call $SP   'convertToAssets(uint256)' 1000000000000000000)
kv "LP share price (before)" "$LP_PRICE_BEFORE"
kv "SP share price (before)" "$SP_PRICE_BEFORE"

send $PRIVATE_KEY $PROXY 'initiateLiquidation(address,address,bytes)' $ADAPTER $ALICE_ADDR $ZERO
echo "  ... sleeping past grace period"
sleep 7
send $PRIVATE_KEY $PROXY 'liquidateBorrower(address,address,address,bytes,uint256)' $ADAPTER $ADAPTER $ALICE_ADDR $ZERO 0

section "  POST-LIQUIDATION state"
kv "Alice debt"            "$(call $DEBT 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "Alice collateral"      "$(call $ADAPTER 'balanceOf(address)(uint256)' $ALICE_ADDR)"
kv "AMFI in SVault"        "$(call $AMFI 'balanceOf(address)(uint256)' $SVAULT)"
kv "SVault pegGapPending"  "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "LP share price"        "$(call $POOL 'convertToAssets(uint256)' 1000000000000000000)"
kv "SP share price"        "$(call $SP   'convertToAssets(uint256)' 1000000000000000000)"

section "9. Settle redemption with 110% return → bonus stream"
PEG_GAP=$(call $SVAULT 'pegGapPendingForSP()(uint256)' | awk '{print $1}')
SETTLE_AMOUNT=$(python3 -c "print(int($PEG_GAP) * 110 // 100)")
kv "Pegged gap"      "$PEG_GAP"
kv "Settling with"   "$SETTLE_AMOUNT (110%)"

send $PRIVATE_KEY $USDR 'mint(address,uint256)' $DEPLOYER $SETTLE_AMOUNT
send $PRIVATE_KEY $USDR 'approve(address,uint256)' $SVAULT $SETTLE_AMOUNT
send $PRIVATE_KEY $SVAULT 'settleRedemption(uint256,uint256)' 1 $SETTLE_AMOUNT

section "  POST-SETTLE state"
kv "SVault pegGapPending" "$(call $SVAULT 'pegGapPendingForSP()(uint256)')"
kv "SP totalAssets"       "$(call $SP   'totalAssets()(uint256)')"
kv "SP share price"       "$(call $SP   'convertToAssets(uint256)' 1000000000000000000)"

section "10. Pro-rata earn — every agaSP holder pumped"
echo ""
echo "  Holder           agaSP balance              USDr-equivalent value"
echo "  ───────────────  ─────────────────────────  ─────────────────────"
for pair in "RF:$RF" "Treasury:$TREASURY" "Bob:$BOB_ADDR" "Charlie:$CHARLIE_ADDR"; do
  label="${pair%%:*}"; addr="${pair##*:}"
  agasp=$(call $SP 'balanceOf(address)(uint256)' $addr | awk '{print $1}')
  if [ "$agasp" = "0" ]; then
    printf "  %-15s  %-25s  %s\n" "$label" "0" "0"
    continue
  fi
  agtoken=$(call $SP   'convertToAssets(uint256)' $agasp | awk '{print $1}')
  usdr=$(call    $POOL 'convertToAssets(uint256)' $agtoken | awk '{print $1}')
  agasp_fmt=$(python3 -c "print(f'{int(\"$agasp\")/1e18:>20,.2f}')")
  usdr_fmt=$(python3 -c "print(f'{int(\"$usdr\")/1e18:>20,.4f}')")
  printf "  %-15s  %s agaSP  %s USDr\n" "$label" "$agasp_fmt" "$usdr_fmt"
done

section "DONE"
echo "Multi-actor E2E complete on chain 7295799."

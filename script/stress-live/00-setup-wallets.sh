#!/usr/bin/env bash
# Stress-live setup — fund 30 fresh wallets with native USDr (gas) and
# mint MockUSDr + 6 tranche tokens to each one.
#
# BUDGET: 0.5 USDr funding × 30 wallets = 15 USDr native gas spend.
# After this script, every wallet can run any scenario in cat 1-9.

source "$(dirname "$0")/_lib.sh"

section "STRESS SETUP — Funding 30 wallets"
kv "Deployer pre-balance" "$(deployer_balance) USDr"

ROLES=(WHALE MIDCAP RETAIL CONSERVATIVE MODERATE AGGRESSIVE)
FUND_AMOUNT="500000000000000000"  # 0.5 USDr in wei
TOKENS=( "$USDR" "$SRESOLV_TOKEN" "$JRESOLV_TOKEN" "$SDIGCAP_TOKEN" "$JDIGCAP_TOKEN" "$SCONDO_TOKEN" "$JCONDO_TOKEN" )
TOKEN_LABELS=( USDr sRESOLV jRESOLV sDIGCAP jDIGCAP sCONDO jCONDO )
MINT_AMOUNT="1000000000000000000000000"  # 1M tokens each

n_wallets=0

for role in "${ROLES[@]}"; do
  for i in 0 1 2 3 4; do
    addr_var="${role}_${i}_ADDR"
    pk_var="${role}_${i}_PK"
    addr="${!addr_var}"
    pk="${!pk_var}"

    if [ -z "$addr" ] || [ -z "$pk" ]; then
      echo "  SKIP missing $addr_var"
      continue
    fi

    # Native USDr funding
    cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$addr" --value "$FUND_AMOUNT" 2>&1 | grep -E '^status' | head -1 || true
    n_wallets=$((n_wallets + 1))
    printf "  [%2d] %-15s %s funded\n" "$n_wallets" "${role}_${i}" "$addr"
  done
done

note_gas "wallet_funding_30x0.5" "15.0"
kv "Deployer post-funding" "$(deployer_balance) USDr"

section "STRESS SETUP — Mint mocks (each wallet gets 1M of every token)"
# To save txs, we mint from the DEPLOYER (admin) directly to each wallet.
# 30 wallets × 7 tokens = 210 mint txs. Gas is cheap on Rayls.
n_mints=0
for role in "${ROLES[@]}"; do
  for i in 0 1 2 3 4; do
    addr_var="${role}_${i}_ADDR"
    addr="${!addr_var}"
    [ -z "$addr" ] && continue

    for k in "${!TOKENS[@]}"; do
      tok="${TOKENS[$k]}"
      cast send --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$tok" \
        'mint(address,uint256)' "$addr" "$MINT_AMOUNT" 2>&1 | grep -E '^(status|Error)' | head -1 > /dev/null || true
      n_mints=$((n_mints + 1))
    done
    printf "  [%2d] %-15s %s minted (7 tokens)\n" "$((n_mints / 7))" "${role}_${i}" "$addr"
  done
done

section "STRESS SETUP — Reset all 6 oracles to 1.0"
for ora in $SRESOLV_ORACLE $JRESOLV_ORACLE $SDIGCAP_ORACLE $JDIGCAP_ORACLE $SCONDO_ORACLE $JCONDO_ORACLE; do
  send $PRIVATE_KEY $ora 'setPrice(uint256)' $ONE
done

section "DONE"
kv "Wallets funded"        "$n_wallets"
kv "Token mints sent"      "$n_mints"
kv "Deployer final"        "$(deployer_balance) USDr"
echo "  Ready for cat scenarios."

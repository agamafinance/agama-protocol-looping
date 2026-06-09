#!/usr/bin/env bash
# End-to-end test of the full Agama Stellar POC against the LIVE testnet.
#
# Covers, with assertions:
#   core : faucet USDC -> mint agUSD 1:1 -> redeem 1:1 -> stake sagUSD ->
#          accrue_yield (NAV & share price rise) -> request_unstake -> cooldown
#          blocks claim -> claim pays out with profit
#   per-vault (x6, 3 Qiro + 3 Tenka): deposit USDC -> shares minted at NAV ->
#          accrue_yield -> share price rises -> request_unstake -> claim
#
# Usage: bash scripts/e2e-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=testnet

DEP=deployments/testnet.json
USDC=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['usdc'])")
AGUSD=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['agusd'])")
SAG=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['staking'])")
VAULTS=$(python3 -c "import json;print(' '.join(f'{k}={v}' for k,v in json.load(open('$DEP'))['creditVaults'].items()))")

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
assert_eq() { # label actual expected
  if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi
}
assert_gt() { # label actual floor
  if [ "$(python3 -c "print(1 if int('$2'.strip('\"')) > int('$3') else 0)")" = "1" ]; then
    ok "$1 ($2 > $3)"; else bad "$1: got $2, want > $3"; fi
}

inv()  { stellar contract invoke --id "$1" --source "$2" --network $NET -- "${@:3}" 2>/dev/null; }

echo "== setup: fresh test user (funded via friendbot) =="
stellar keys generate e2e-user --network testnet --fund --overwrite >/dev/null 2>&1
USER=$(stellar keys address e2e-user)
echo "  user=$USER"

echo ""
echo "== CORE FLOW: USDC -> agUSD -> sagUSD =="
inv $USDC e2e-user faucet --to $USER --amount 20000000000 >/dev/null   # 2,000 USDC
assert_eq "faucet: USDC balance" "$(inv $USDC e2e-user balance --id $USER)" '"20000000000"'

inv $AGUSD e2e-user deposit --from $USER --amount 10000000000 >/dev/null  # 1,000
assert_eq "mint 1:1: agUSD balance" "$(inv $AGUSD e2e-user balance --id $USER)" '"10000000000"'

inv $AGUSD e2e-user redeem --from $USER --amount 2000000000 >/dev/null    # redeem 200
assert_eq "redeem 1:1: agUSD balance" "$(inv $AGUSD e2e-user balance --id $USER)" '"8000000000"'
assert_eq "redeem 1:1: USDC back" "$(inv $USDC e2e-user balance --id $USER)" '"12000000000"'

SP0=$(inv $SAG e2e-user share_price)
inv $SAG e2e-user stake --from $USER --amount 8000000000 >/dev/null       # stake 800 agUSD
SHARES=$(inv $SAG e2e-user balance --id $USER)
assert_gt "stake: sagUSD shares minted" "$SHARES" "0"

inv $SAG agama-poc accrue_yield --amount 5000000000 >/dev/null            # +500 agUSD yield
SP1=$(inv $SAG e2e-user share_price)
assert_gt "accrue_yield: share price rose" "$SP1" "$(echo $SP0 | tr -d '\"')"

S=$(echo $SHARES | tr -d '"')
inv $SAG e2e-user request_unstake --from $USER --shares $S >/dev/null
CLAIM_EARLY=$(inv $SAG e2e-user claim --from $USER 2>&1 | head -1)
if inv $SAG e2e-user claim --from $USER >/dev/null 2>&1; then
  bad "cooldown should block early claim"
else
  ok "cooldown blocks early claim"
fi

echo "  …waiting out the sagUSD cooldown (60s)…"
sleep 62
CLAIMED=$(inv $SAG e2e-user claim --from $USER)
assert_gt "claim after cooldown: agUSD payout > principal (yield!)" "$CLAIMED" "8000000000"

echo ""
echo "== CREDIT VAULTS (3 Qiro + 3 Tenka): deposit USDC, earn, exit =="
for kv in $VAULTS; do
  slug="${kv%%=*}"; VID="${kv#*=}"
  echo "-- $slug --"
  inv $USDC e2e-user faucet --to $USER --amount 1000000000 >/dev/null     # 100 USDC
  SP0=$(inv $VID e2e-user share_price)
  inv $VID e2e-user stake --from $USER --amount 1000000000 >/dev/null
  VS=$(inv $VID e2e-user balance --id $USER)
  assert_gt "deposit: shares minted" "$VS" "0"

  # strategist funds yield with USDC then accrues it into the vault
  inv $USDC agama-poc faucet --to $(stellar keys address agama-poc) --amount 100000000 >/dev/null
  inv $VID agama-poc accrue_yield --amount 100000000 >/dev/null           # +10 USDC
  SP1=$(inv $VID e2e-user share_price)
  assert_gt "yield: share price rose" "$SP1" "$(echo $SP0 | tr -d '\"')"

  V=$(echo $VS | tr -d '"')
  inv $VID e2e-user request_unstake --from $USER --shares $V >/dev/null
  sleep 11                                                               # vault cooldown 10s
  OUT=$(inv $VID e2e-user claim --from $USER)
  assert_gt "exit: USDC payout > principal" "$OUT" "1000000000"
done

echo ""
echo "================================"
echo " E2E RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]

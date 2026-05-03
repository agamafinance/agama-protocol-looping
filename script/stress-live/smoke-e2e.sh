#!/usr/bin/env bash
# Smoke E2E — covers every protocol surface in <1 minute on the LIVE
# chain, no time skipping. Validates that the deployed V2 stack is
# reachable + functional after the latest redeploy.
#
# Path:
#   1. mint USDr
#   2. deposit USDr → agYLD via LendingPool.deposit (ERC4626)
#   3. stake some agYLD into SP → sagYLD
#   4. mint sRESOLV tranche tok
#   5. openVaultPosition + depositAsset(sRESOLV) as collateral
#   6. borrow 100 USDr against it
#   7. repay full
#   8. withdraw all collateral
#   9. requestUnstake half the SP position (cooldown 7d → no claim)
#  10. read every key view back
set +e
source "$(dirname "$0")/_lib.sh"

PK="$PRIVATE_KEY"; ME="$DEPLOYER"
RPC="$RAYLS_TESTNET_RPC"
ZERO=$(cast abi-encode 'f(uint256)' 0)

xs() { cast send --rpc-url "$RPC" --private-key "$1" "${@:2}" 2>&1 | grep -E "^(status|Error|revert)" | head -1; }
xc() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | head -1 | awk '{print $1}'; }
phase(){ echo ""; echo "── $1"; }
ok(){ printf "    ✓ %s\n" "$1"; }
ko(){ printf "    ✗ %s\n" "$1"; SMOKE_FAIL=1; }
expect_nonzero(){ local v="$1" label="$2"; if [ "$v" = "0" ] || [ -z "$v" ]; then ko "$label = $v"; else ok "$label = $v"; fi; }

SMOKE_FAIL=0
echo "════════════════════════════════════════════════════════"
echo "  SMOKE E2E — V2 cooldown stack on Rayls testnet"
echo "════════════════════════════════════════════════════════"
echo "  RPC:      $RPC"
echo "  Deployer: $ME"
echo "  USDr:     $USDR"
echo "  Pool:     $POOL"
echo "  SP:       $SP"

# 1. mint USDr
phase "1. mint USDr 100k"
xs "$PK" "$USDR" 'mint(address,uint256)' "$ME" 100000000000000000000000 >/dev/null
ok "minted"

# 2. deposit
phase "2. deposit 50k USDr → agYLD"
xs "$PK" "$USDR" 'approve(address,uint256)' "$POOL" 50000000000000000000000 >/dev/null
xs "$PK" "$POOL" 'deposit(uint256,address)' 50000000000000000000000 "$ME" >/dev/null
ag=$(xc $POOL 'balanceOf(address)(uint256)' $ME)
expect_nonzero "$ag" "agYLD"

# 3. stake into SP
phase "3. stake 1/5 of agYLD → sagYLD"
stake_amt=$(python3 -c "print(int('$ag') // 5)")
xs "$PK" "$POOL" 'approve(address,uint256)' "$SP" "$stake_amt" >/dev/null
xs "$PK" "$SP" 'deposit(uint256,address)' "$stake_amt" "$ME" >/dev/null
sag=$(xc $SP 'balanceOf(address)(uint256)' $ME)
expect_nonzero "$sag" "sagYLD"

# 4. mint tranche
phase "4. mint sRESOLV 10k"
xs "$PK" "$SRESOLV_TOKEN" 'mint(address,uint256)' "$ME" 10000000000000000000000 >/dev/null
tr=$(xc $SRESOLV_TOKEN 'balanceOf(address)(uint256)' $ME)
expect_nonzero "$tr" "sRESOLV wallet"

# 5. open vault position + depositAsset 5k sRESOLV
phase "5. depositAsset 5k sRESOLV as collateral"
COL=5000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' $COL)
xs "$PK" "$POOL" 'openVaultPosition()' >/dev/null
xs "$PK" "$SRESOLV_TOKEN" 'approve(address,uint256)' "$SRESOLV_ADAPTER" "$COL" >/dev/null
xs "$PK" "$POOL" 'depositAsset(address,bytes)' "$SRESOLV_ADAPTER" "$DATA" >/dev/null
col=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' $ME)
expect_nonzero "$col" "collateral at adapter"

# 6. borrow 100 USDr
phase "6. borrow 100 USDr"
BORROW=100000000000000000000
xs "$PK" "$POOL" 'borrow(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" "$BORROW" >/dev/null
debt=$(xc $DEBT 'balanceOf(address)(uint256)' $ME)
expect_nonzero "$debt" "DebtToken balance"
hf=$(xc $POOL 'calculateHealthFactor(address,address,bytes)(uint256)' "$SRESOLV_ADAPTER" "$ME" "$ZERO")
ok "HF post-borrow: $hf"

# 7. repay full
phase "7. repay full"
# Add a small buffer for accrual between read and tx
REPAY=$(python3 -c "print(int('$debt') * 11 // 10)")
xs "$PK" "$USDR" 'approve(address,uint256)' "$POOL" "$REPAY" >/dev/null
xs "$PK" "$POOL" 'repay(address,bytes,uint256)' "$SRESOLV_ADAPTER" "$ZERO" "$REPAY" >/dev/null
debt2=$(xc $DEBT 'balanceOf(address)(uint256)' $ME)
if [ "$debt2" = "0" ]; then ok "debt cleared"; else ko "debt residual = $debt2"; fi

# 8. withdraw all collateral
phase "8. withdrawAsset all"
WDATA=$(cast abi-encode 'f(uint256)' $col)
xs "$PK" "$POOL" 'withdrawAsset(address,bytes)' "$SRESOLV_ADAPTER" "$WDATA" >/dev/null
col2=$(xc $SRESOLV_ADAPTER 'balanceOf(address)(uint256)' $ME)
if [ "$col2" = "0" ]; then ok "collateral fully withdrawn"; else ko "collateral residual = $col2"; fi

# 9. requestUnstake half the sagYLD (don't claim — cooldown is 7d)
phase "9. requestUnstake half"
half=$(python3 -c "print(int('$sag') // 2)")
xs "$PK" "$SP" 'requestUnstake(uint256)' "$half" >/dev/null
em=$(xc $SP 'earmarkedShares(address)(uint256)' $ME)
expect_nonzero "$em" "earmarkedShares"

# 10. read protocol views
phase "10. read protocol views"
spTotal=$(xc $SP 'totalAssets()(uint256)')
expect_nonzero "$spTotal" "SP totalAssets"
sett=$(xc $SVAULT 'latestPendingSettlementCloseTime()(uint256)')
ok "SVault.latestPendingSettlementCloseTime = $sett"
cd_now=$(xc $SP 'cooldownDuration()(uint256)')
ok "SP.cooldownDuration = $cd_now"
poolTA=$(xc $POOL 'totalAssets()(uint256)')
expect_nonzero "$poolTA" "Pool totalAssets"

echo ""
echo "════════════════════════════════════════════════════════"
if [ $SMOKE_FAIL -eq 0 ]; then
  echo "  ✓ SMOKE E2E PASS — full V2 surface exercised on chain"
else
  echo "  ✗ SMOKE E2E FAIL — see lines marked '✗' above"
fi
echo "════════════════════════════════════════════════════════"
exit $SMOKE_FAIL

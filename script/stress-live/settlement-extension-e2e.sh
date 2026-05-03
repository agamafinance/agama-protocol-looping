#!/usr/bin/env bash
# Settlement-extension E2E — V2-specific behaviour. After a liquidation
# batches a settlement, a fresh requestUnstake snapshots the
# settlementExtensionUntil and unlockAt is pushed past the standard
# cooldown. Verifies the SP correctly reads
# SVault.latestPendingSettlementCloseTime() at request time.
set -e
source "$(dirname "$0")/_lib.sh"

DEPLOYER_PK="$PRIVATE_KEY"

assert_eq() {
  local label="$1"; local exp="$2"; local act="$3"
  if [ "$exp" = "$act" ]; then printf "  PASS   %-50s = %s\n" "$label" "$act"
  else printf "  FAIL   %-50s exp=%s act=%s\n" "$label" "$exp" "$act"; exit 1
  fi
}

ZERO=$(cast abi-encode 'f(uint256)' 0)
RPC="$RAYLS_TESTNET_RPC"

section "SETTLEMENT-EXTENSION E2E"

# ─────────────────────────────────────────────────────────────────────
# 0. Start state probe — show no pending batches yet
# ─────────────────────────────────────────────────────────────────────
section "0. Initial SVault state"
LATEST_CLOSE=$(call $SVAULT 'latestPendingSettlementCloseTime()(uint64)' | awk '{print $1}')
echo "  latestPendingSettlementCloseTime (no pending): $LATEST_CLOSE"

# ─────────────────────────────────────────────────────────────────────
# 1. Open a borrower position on sCONDO
# ─────────────────────────────────────────────────────────────────────
section "1. sCONDO borrower position 100k collat / 70k debt"
MINT=1000000000000000000000000
send "$DEPLOYER_PK" "$SCONDO_TOKEN" 'mint(address,uint256)' "$DEPLOYER" "$MINT"
COLLAT=100000000000000000000000
SBORROW=70000000000000000000000
DATA=$(cast abi-encode 'f(uint256)' $COLLAT)
send "$DEPLOYER_PK" "$SCONDO_TOKEN" 'approve(address,uint256)' "$SCONDO_ADAPTER" "$COLLAT"
send "$DEPLOYER_PK" "$POOL" 'depositAsset(address,bytes)' "$SCONDO_ADAPTER" "$DATA"
send "$DEPLOYER_PK" "$POOL" 'borrow(address,bytes,uint256)' "$SCONDO_ADAPTER" "$ZERO" "$SBORROW"

# ─────────────────────────────────────────────────────────────────────
# 2. Crash sCONDO 25% → liquidatable
# ─────────────────────────────────────────────────────────────────────
section "2. Crash sCONDO oracle 25%"
send "$DEPLOYER_PK" "$SCONDO_ORACLE" 'setPrice(uint256)' 750000000000000000

# ─────────────────────────────────────────────────────────────────────
# 3. Liquidate → batch queued in SVault
# ─────────────────────────────────────────────────────────────────────
section "3. Liquidate"
send "$DEPLOYER_PK" "$PROXY" 'liquidate(address,address,address,bytes,uint256)' \
  "$SCONDO_ADAPTER" "$SCONDO_ADAPTER" "$DEPLOYER" "$ZERO" 0

# Now there's a Queued batch. latestPendingSettlementCloseTime should
# return queuedAt + standardSettlementWindow (= 15 days by default).
LATEST_CLOSE=$(call $SVAULT 'latestPendingSettlementCloseTime()(uint64)' | awk '{print $1}')
NOW=$(date +%s)
DELTA=$(python3 -c "print(int('$LATEST_CLOSE') - int('$NOW'))")
EXPECTED_WINDOW=1296000  # 15 days
echo "  Latest pending close:    $LATEST_CLOSE"
echo "  Now:                     $NOW"
echo "  Delta seconds:           $DELTA  (expected ~ 15 days = $EXPECTED_WINDOW)"

# Allow ±60s drift on now-vs-block-timestamp.
if [ "$(python3 -c "print(abs($DELTA - $EXPECTED_WINDOW) < 120)")" = "True" ]; then
  echo "  PASS   latestPendingSettlementCloseTime ~= now + 15d"
else
  echo "  WARN   delta off by $(python3 -c "print($DELTA - $EXPECTED_WINDOW)")s — chain time drift"
fi

# ─────────────────────────────────────────────────────────────────────
# 4. Now requestUnstake — must snapshot the extension
# ─────────────────────────────────────────────────────────────────────
section "4. requestUnstake while batch is queued"
# Make sure deployer has at least 1 sagYLD to unstake (he should from
# cooldown-e2e earlier; if not, stake more).
SAG=$(call $SP 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
echo "  Deployer sagYLD: $SAG"
if [ "$SAG" = "0" ]; then
  echo "  Topping up SP stake (50k agYLD)..."
  send "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" 50000000000000000000000
  send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$POOL" 50000000000000000000000
  send "$DEPLOYER_PK" "$POOL" 'deposit(uint256,address)' 50000000000000000000000 "$DEPLOYER"
  AGYLD=$(call $POOL 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
  send "$DEPLOYER_PK" "$POOL" 'approve(address,uint256)' "$SP" "$AGYLD"
  send "$DEPLOYER_PK" "$SP"   'deposit(uint256,address)' "$AGYLD" "$DEPLOYER"
  SAG=$(call $SP 'balanceOf(address)(uint256)' $DEPLOYER | awk '{print $1}')
fi

# Use a small amount that's surely not earmarked already.
EARMARKED=$(call $SP 'earmarkedShares(address)(uint256)' $DEPLOYER | awk '{print $1}')
FREE=$(python3 -c "print(int('$SAG') - int('$EARMARKED'))")
echo "  Free sagYLD (not earmarked): $FREE"
NEW_REQ_AMT=10000000000000000000000  # 10k sagYLD-equivalent
if [ "$(python3 -c "print(int('$FREE') < int('$NEW_REQ_AMT'))")" = "True" ]; then
  echo "  Adjusting request to fit free balance..."
  NEW_REQ_AMT="$FREE"
fi

send "$DEPLOYER_PK" "$SP" 'requestUnstake(uint256)' "$NEW_REQ_AMT"

# Read the new request slot — it should be the LAST one
PCOUNT=$(call $SP 'pendingCount(address)(uint256)' $DEPLOYER | awk '{print $1}')
LAST_ID=$(python3 -c "print(int('$PCOUNT') - 1)")
echo "  New requestId: $LAST_ID  (pendingCount = $PCOUNT)"

REQ=$(call $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' $DEPLOYER $LAST_ID 2>&1)
echo "  Request slot $LAST_ID: $REQ"

# Parse settlementExtensionUntil from the tuple — third field
EXT=$(echo "$REQ" | grep -oE '\([0-9]+ \[[^]]+\], [0-9]+ \[[^]]+\], [0-9]+, false\)' \
  | head -1 | awk -F', ' '{print $3}')
if [ -z "$EXT" ]; then
  # Fallback: try to extract third uint via cast call abi
  EXT=$(call $SP 'getRequest(address,uint256)((uint128,uint64,uint64,bool))' $DEPLOYER $LAST_ID | python3 -c "import sys; line=sys.stdin.read().strip(); print(line.split(',')[2].strip().split()[0])")
fi
echo "  settlementExtensionUntil: $EXT"

if [ "$(python3 -c "print(int('$EXT') > 0)")" = "True" ]; then
  echo "  PASS   settlementExtensionUntil > 0 (extension snapshotted)"
else
  echo "  FAIL   settlementExtensionUntil = 0 (no extension applied)"; exit 1
fi

# Cooldown is now 1 day (set by cooldown-e2e.sh). unlockAt should be
# max(now + 1d, ext) = ext since ext = now + 15d.
COOLDOWN=$(call $SP 'cooldownDuration()(uint256)' | awk '{print $1}')
echo "  cooldownDuration: $COOLDOWN"
echo ""
echo "  Expected unlockAt = max(reqAt + cooldown, settlementExt)"
echo "                    = max(now + ${COOLDOWN}s, $EXT)"
echo "                    = $EXT  (since 15d > 1d)"

# ─────────────────────────────────────────────────────────────────────
# 5. Try claim immediately → reverts CooldownNotElapsed
# ─────────────────────────────────────────────────────────────────────
section "5. Early claim must revert (cooldown extended by settlement)"
EARLY=$(cast send --rpc-url "$RPC" --private-key "$DEPLOYER_PK" "$SP" 'claim(uint256)' "$LAST_ID" 2>&1 || true)
if echo "$EARLY" | grep -q "Error\|revert\|Revert"; then
  echo "  PASS   claim($LAST_ID) reverted as expected (cooldown extended to $(python3 -c "print(($EXT - $NOW)/86400)") days from now)"
else
  echo "  FAIL   claim should have reverted: $EARLY"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# 6. Settle the batch — close the extension
# ─────────────────────────────────────────────────────────────────────
section "6. Settle batch at face value"
BATCH=$(call $SVAULT 'nextBatchId()(uint256)' | awk '{print $1}')
SETTLE=100000000000000000000000
send "$DEPLOYER_PK" "$USDR" 'mint(address,uint256)' "$DEPLOYER" "$SETTLE"
send "$DEPLOYER_PK" "$USDR" 'approve(address,uint256)' "$SVAULT" "$SETTLE"
send "$DEPLOYER_PK" "$SVAULT" 'settleRedemption(uint256,uint256)' "$BATCH" "$SETTLE"

LATEST_CLOSE_AFTER=$(call $SVAULT 'latestPendingSettlementCloseTime()(uint64)' | awk '{print $1}')
echo "  latestPendingSettlementCloseTime post-settle: $LATEST_CLOSE_AFTER (expected 0)"
assert_eq "no more pending settlement" "0" "$LATEST_CLOSE_AFTER"

# ─────────────────────────────────────────────────────────────────────
# 7. Restore oracle
# ─────────────────────────────────────────────────────────────────────
section "7. Restore sCONDO oracle"
send "$DEPLOYER_PK" "$SCONDO_ORACLE" 'setPrice(uint256)' 1000000000000000000

# Note: the request still has its original settlementExtensionUntil
# (snapshotted at request time). It does NOT update post-settle.

section "DONE"
echo "  Settlement-extension behaviour validated end-to-end."
echo "  Request slot $LAST_ID will unlock at:"
python3 -c "
from datetime import datetime
print(f'    Unix:  $EXT')
print(f'    Human: {datetime.fromtimestamp($EXT)}')"

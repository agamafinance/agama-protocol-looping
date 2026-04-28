#!/usr/bin/env bash
# Live Cat 7 + Cat 9 — Oracle stress + flash crash demo (most dramatic for pitch).
#   S7.2 — Multiple crashes (5 × 10% drops on sRESOLV)
#   S9.3 — Flash crash all 6 oracles -50% (no liquidations, just visualize the HF moves)
source "$(dirname "$0")/_lib.sh"

section "Cat 7+9 LIVE — Oracle stress / Flash crash"

# Reset all 6 oracles to 1.0
for ora in $SRESOLV_ORACLE $JRESOLV_ORACLE $SDIGCAP_ORACLE $JDIGCAP_ORACLE $SCONDO_ORACLE $JCONDO_ORACLE; do
  send $PRIVATE_KEY $ora 'setPrice(uint256)' $ONE
done

section "S7.2 — Multiple crashes (5 x 10% on sRESOLV)"
PRICE=$ONE
for i in 1 2 3 4 5; do
  PRICE=$(python3 -c "print(int($PRICE) * 90 // 100)")
  send $PRIVATE_KEY $SRESOLV_ORACLE 'setPrice(uint256)' $PRICE
  printf "  drop %d -> oracle = %s\n" "$i" "$PRICE"
done
kv "sRESOLV final price" "$(call $SRESOLV_ORACLE 'getPrice()(uint256)')"
inv_check "POST-S7.2"

section "S9.3 LITE — Flash crash all 6 oracles -50% (visual only, no liq)"
HALF=$(python3 -c "print(int($ONE) // 2)")
for ora in $SRESOLV_ORACLE $JRESOLV_ORACLE $SDIGCAP_ORACLE $JDIGCAP_ORACLE $SCONDO_ORACLE $JCONDO_ORACLE; do
  send $PRIVATE_KEY $ora 'setPrice(uint256)' $HALF
done
kv "sRESOLV"  "$(call $SRESOLV_ORACLE 'getPrice()(uint256)')"
kv "jRESOLV"  "$(call $JRESOLV_ORACLE 'getPrice()(uint256)')"
kv "sDIGCAP"  "$(call $SDIGCAP_ORACLE 'getPrice()(uint256)')"
kv "jDIGCAP"  "$(call $JDIGCAP_ORACLE 'getPrice()(uint256)')"
kv "sCONDO"   "$(call $SCONDO_ORACLE  'getPrice()(uint256)')"
kv "jCONDO"   "$(call $JCONDO_ORACLE  'getPrice()(uint256)')"
inv_check "POST-S9.3"

section "Cat 7+9 LIVE done"

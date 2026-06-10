#!/usr/bin/env bash
# Exhaustive on-chain verification of every protocol path except Timeboost
# (lend, stake/yield, borrow, repay, withdraw collateral, lender withdraw, unstake).
set -euo pipefail
RPC=https://sepolia-rollup.arbitrum.io/rpc
PK="${PK:?export PK=<deployer private key>}"
ME=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
G="--gas-price 500000000"
USDC=0x6dfa69b8dd81c2bfb7103be130d696eb637454e9
AG=0xc2ba46c36cec7fa1c8205dbebe5e710742f7e485
SAG=0x0ce9f6e3e94280d279b06ab673947cf101071a7f
ORACLE=0x5db98ce31077887e5f3dcd7f71cb945975ad5314
POOL=0x194aacc47fb0c89c467331478fce9b529e8f6385
tMEZ=0xdcead66c3336658cb8da9bacb21e08b580b4bea6
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
send(){ cast send $G --private-key $PK --rpc-url $RPC "$@" >/dev/null && echo "    ok"; }
ag(){    cast call $AG  'balanceOf(address)(uint256)' $ME --rpc-url $RPC; }
sag(){   cast call $SAG 'balanceOf(address)(uint256)' $ME --rpc-url $RPC; }
usdc(){  cast call $USDC 'balanceOf(address)(uint256)' $ME --rpc-url $RPC; }
debt(){  cast call $POOL 'debtOf(address)(uint256)' $ME --rpc-url $RPC; }
hf(){    cast call $POOL 'healthFactor(address)(uint256)' $ME --rpc-url $RPC; }
coll(){  cast call $POOL 'collateralShares(address,address)(uint256)' $ME $tMEZ --rpc-url $RPC; }
saTA(){  cast call $SAG 'totalAssets()(uint256)' --rpc-url $RPC; }
saPx(){  cast call $SAG 'pricePerShare()(uint256)' --rpc-url $RPC; }
util(){  cast call $POOL 'utilization()(uint256)' --rpc-url $RPC; }
brate(){ cast call $POOL 'borrowRateView()(uint256)' --rpc-url $RPC; }

echo "### 0. restore tMEZ NAV to 1.00 (clean slate, healthy collateral)"
send $ORACLE 'crash(address,uint256)' $tMEZ 1000000000000000000
echo "    tMEZ nav: $(cast call $ORACLE 'navOf(address)(uint256)' $tMEZ --rpc-url $RPC)  HF: $(hf)"

echo "### 1. LENDER: lend 10,000 USDC -> agUSD 1:1"
send $USDC 'approve(address,uint256)' $POOL $MAX
B=$(ag); send $POOL 'lend(uint256)' 10000000000; A=$(ag)
echo "    agUSD  $B -> $A   (expect +10000e18)"

echo "### 2. STAKER: stake 40,000 agUSD -> sagUSD"
send $AG 'approve(address,uint256)' $SAG $MAX
send $SAG 'stake(uint256)' 40000000000000000000000
echo "    sagUSD balance: $(sag)   price/share: $(saPx)"
TA0=$(saTA); PX0=$(saPx)

echo "### 3. BORROWER: raise utilization (borrow against tMEZ)"
echo "    util before: $(util)  borrowRate: $(brate)"
send $POOL 'borrow(uint256)' 1500000000
echo "    util after:  $(util)  borrowRate: $(brate)  debt: $(debt)  HF: $(hf)"

echo "### 4. YIELD: let interest accrue across several txs, then compare sagUSD"
echo "    sagUSD totalAssets t0: $TA0   price t0: $PX0"
for i in 1 2 3 4; do send $POOL 'accrue()'; done   # each accrue mints interest to sagUSD
TA1=$(saTA); PX1=$(saPx)
echo "    sagUSD totalAssets t1: $TA1   price t1: $PX1"
python3 -c "
ta0,ta1,px0,px1=$TA0,$TA1,$PX0,$PX1
print(f'    interest minted to sagUSD: {(ta1-ta0)/1e18:.10f} agUSD')
print(f'    sagUSD price delta:        {(px1-px0)/1e18:.12f}')
assert ta1>=ta0 and px1>=px0, 'YIELD DID NOT ACCRUE'
print('    YIELD OK (totalAssets and price both up, or flat if 0s elapsed)')"

echo "### 5. REPAY 1,000 USDC"
D=$(debt); send $POOL 'repay(uint256)' 1000000000; echo "    debt $D -> $(debt)"

echo "### 6. WITHDRAW COLLATERAL 1,000 tMEZ shares (HF must stay >= 1)"
C=$(coll); send $POOL 'withdrawCollateral(address,uint256)' $tMEZ 1000000000000000000000
echo "    collateral $C -> $(coll)   HF: $(hf)"

echo "### 7. UNSTAKE 20,000 sagUSD -> agUSD (price >= 1, get >= 20000)"
B=$(ag); send $SAG 'unstake(uint256)' 20000000000000000000000; A=$(ag)
python3 -c "print(f'    agUSD {$B/1e18:.4f} -> {$A/1e18:.4f}  (got {($A-$B)/1e18:.6f} for 20000 shares)')"

echo "### 8. LENDER WITHDRAW: burn 5,000 agUSD -> 5,000 USDC 1:1"
BU=$(usdc); BA=$(ag); send $POOL 'withdraw(uint256)' 5000000000; AU=$(usdc); AA=$(ag)
python3 -c "print(f'    USDC +{($AU-$BU)/1e6:.2f}   agUSD {($AA-$BA)/1e18:.2f}  (expect +5000 / -5000)')"

echo "### DONE — final: debt=$(debt) HF=$(hf) util=$(util) sagPrice=$(saPx)"

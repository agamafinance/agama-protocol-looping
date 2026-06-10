#!/usr/bin/env bash
# Full lifecycle on Arbitrum Sepolia: faucet -> lend -> collateral -> borrow ->
# NAV crash -> liquidate. Same wallet plays lender, borrower and liquidator.
set -euo pipefail
RPC=https://sepolia-rollup.arbitrum.io/rpc
PK="${PK:?export PK=<deployer private key>}"
ME=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
GAS="--gas-price 500000000"
USDC=0x6dfa69b8dd81c2bfb7103be130d696eb637454e9
ORACLE=0x5db98ce31077887e5f3dcd7f71cb945975ad5314
POOL=0x194aacc47fb0c89c467331478fce9b529e8f6385
tMEZ=0xdcead66c3336658cb8da9bacb21e08b580b4bea6
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
send(){ cast send $GAS --private-key $PK --rpc-url $RPC "$@" >/dev/null && echo ok; }
hf(){ cast call $POOL 'healthFactor(address)(uint256)' $ME --rpc-url $RPC; }
debt(){ cast call $POOL 'debtOf(address)(uint256)' $ME --rpc-url $RPC; }

echo "faucet 100k + 100k USDC";  send $USDC 'faucet(uint256)' 100000000000; send $USDC 'faucet(uint256)' 100000000000
echo "approve USDC->pool, USDC->vault"; send $USDC 'approve(address,uint256)' $POOL $MAX; send $USDC 'approve(address,uint256)' $tMEZ $MAX
echo "lend 80k USDC";              send $POOL 'lend(uint256)' 80000000000
echo "deposit 20k USDC into tMEZ"; send $tMEZ 'deposit(uint256)' 20000000000
echo "tMEZ shares: $(cast call $tMEZ 'sharesOf(address)(uint256)' $ME --rpc-url $RPC)"
echo "approve vault shares->pool"; send $tMEZ 'approve(address,uint256)' $POOL $MAX
echo "deposit collateral 19000 shares"; send $POOL 'depositCollateral(address,uint256)' $tMEZ 19000000000000000000000
echo "borrow 9000 USDC";           send $POOL 'borrow(uint256)' 9000000000
echo "HF after borrow: $(hf)  debt: $(debt)"
echo "--- CRASH tMEZ nav to 0.78 (credit event) ---"; send $ORACLE 'crash(address,uint256)' $tMEZ 780000000000000000
echo "HF after crash: $(hf)   (<1e18 => liquidatable)"
echo "--- LIQUIDATE: repay 4000 USDC, seize tMEZ + 10% bonus ---"; send $POOL 'liquidate(address,address,uint256)' $ME $tMEZ 4000000000
echo "HF after liquidation: $(hf)   debt: $(debt)"
echo "DONE"

#!/usr/bin/env bash
# Full lifecycle on the verified deployment. Addresses from new-addrs.env.
set -euo pipefail
source "$(dirname "$0")/new-addrs.env"
RPC=https://sepolia-rollup.arbitrum.io/rpc
PK="${PK:?export PK=<deployer private key>}"
ME=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
send(){ cast send --gas-price 500000000 --private-key $PK --rpc-url $RPC "$@" >/dev/null && echo ok; }
rd(){ cast call --rpc-url $RPC "$@" | awk '{print $1}'; }
hf(){ rd $POOL 'healthFactor(address)(uint256)' $ME; }
debt(){ rd $POOL 'debtOf(address)(uint256)' $ME; }

echo "faucet 100k+100k USDC"; send $USDC 'faucet(uint256)' 100000000000; send $USDC 'faucet(uint256)' 100000000000
echo "approve USDC->pool, USDC->tMEZ"; send $USDC 'approve(address,uint256)' $POOL $MAX; send $USDC 'approve(address,uint256)' $VAULT5 $MAX
echo "lend 80k USDC -> agUSD"; send $POOL 'lend(uint256)' 80000000000
echo "stake 40k agUSD -> sagUSD"; send $AGUSD 'approve(address,uint256)' $SAGUSD $MAX; send $SAGUSD 'stake(uint256)' 40000000000000000000000
echo "mint 20k tMEZ vault shares"; send $VAULT5 'deposit(uint256)' 20000000000
echo "deposit 19k tMEZ as collateral"; send $VAULT5 'approve(address,uint256)' $POOL $MAX; send $POOL 'depositCollateral(address,uint256)' $VAULT5 19000000000000000000000
echo "borrow 9k USDC"; send $POOL 'borrow(uint256)' 9000000000
echo "HF after borrow: $(python3 -c "print($(hf)/1e18)")  debt: $(python3 -c "print($(debt)/1e6)")"
echo "--- CRASH tMEZ -> 0.60 ---"; send $ORACLE 'crash(address,uint256)' $VAULT5 600000000000000000
echo "HF after crash: $(python3 -c "print($(hf)/1e18)")  (<1 liquidatable)"
echo "--- LIQUIDATE repay 4k ---"; send $POOL 'liquidate(address,address,uint256)' $ME $VAULT5 4000000000
echo "HF after liq: $(python3 -c "print($(hf)/1e18)")  debt: $(python3 -c "print($(debt)/1e6)")"
echo "--- restore tMEZ NAV -> 1.00 (clean demo state) ---"; send $ORACLE 'crash(address,uint256)' $VAULT5 1000000000000000000
echo "HF final: $(python3 -c "print($(hf)/1e18)")"
echo "E2E_OK"

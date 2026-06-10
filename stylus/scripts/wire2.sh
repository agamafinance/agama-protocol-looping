#!/usr/bin/env bash
# Re-wire + seed the verified deployment. Addresses sourced from new-addrs.env.
set -euo pipefail
source "$(dirname "$0")/new-addrs.env"
RPC=https://sepolia-rollup.arbitrum.io/rpc
PK="${PK:?export PK=<deployer private key>}"
ME=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
send(){ cast send --gas-price 500000000 --private-key $PK --rpc-url $RPC "$@" >/dev/null && echo "  ok"; }
WAD=1000000000000000000
ltv(){ python3 -c "print(int($1*1e18))"; }
rate(){ python3 -c "print(int($1/10000*1e18/31536000))"; }
cap(){ python3 -c "print(int($1)*10**18)"; }

echo "[1] agUSD.initialize(pool)";   send $AGUSD  "initialize(address)" $POOL
echo "[2] sagUSD.initialize(agusd)"; send $SAGUSD "initialize(address)" $AGUSD
echo "[3] navOracle.initialize()";   send $ORACLE "initialize()"
echo "[4] pool.initialize(...)"
send $POOL "initialize(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256)" \
  $USDC $AGUSD $SAGUSD $ORACLE $ME 0 $(ltv 0.04) $(ltv 0.60) $(ltv 0.80) $(ltv 0.10)

wire_vault(){ # addr symbol apyBps ltv threshold bonus capUsd
  local addr=$1 sym=$2 apy=$3 l=$4 th=$5 bn=$6 cp=$7
  echo "[vault $sym] initialize";   send $addr "initialize(address,address,string)" $USDC $ORACLE "$sym"
  echo "[vault $sym] oracle.setVault"; send $ORACLE "setVault(address,uint256,uint256)" $addr $WAD $(rate $apy)
  echo "[vault $sym] pool.listVault";  send $POOL "listVault(address,uint256,uint256,uint256,uint256)" $addr $(ltv $l) $(ltv $th) $(ltv $bn) $(cap $cp)
}
wire_vault $VAULT1 qPFV 1400 0.75 0.82 0.06 25000000
wire_vault $VAULT2 qPCV 1300 0.70 0.78 0.07 10000000
wire_vault $VAULT3 qICV 1200 0.65 0.73 0.08 15000000
wire_vault $VAULT4 tSNR  850 0.80 0.86 0.05 500000000
wire_vault $VAULT5 tMEZ 1750 0.50 0.60 0.10 200000000
wire_vault $VAULT6 tDV  1100 0.55 0.65 0.09 300000000
echo "WIRED"

#!/usr/bin/env bash
# Wire + seed the Agama Arbitrum protocol on Arbitrum Sepolia.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
RPC=https://sepolia-rollup.arbitrum.io/rpc
PK="${PK:?export PK=<deployer private key>}"
ME=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
GAS="--gas-price 500000000"  # 0.5 gwei, well above Sepolia base fee

USDC=0x6dfa69b8dd81c2bfb7103be130d696eb637454e9
AGUSD=0xc2ba46c36cec7fa1c8205dbebe5e710742f7e485
SAGUSD=0x0ce9f6e3e94280d279b06ab673947cf101071a7f
ORACLE=0x5db98ce31077887e5f3dcd7f71cb945975ad5314
POOL=0x194aacc47fb0c89c467331478fce9b529e8f6385

send() { cast send $GAS --private-key $PK --rpc-url $RPC "$@" >/dev/null && echo "  ok"; }

WAD=1000000000000000000
ltv()  { python3 -c "print(int($1*1e18))"; }
rate() { python3 -c "print(int($1/10000*1e18/31536000))"; }   # apyBps -> wad/sec
cap()  { python3 -c "print(int($1)*10**18)"; }                 # usd -> shares(18dec)

echo "[1] agUSD.initialize(pool)";    send $AGUSD  "initialize(address)" $POOL
echo "[2] sagUSD.initialize(agusd)";  send $SAGUSD "initialize(address)" $AGUSD
echo "[3] navOracle.initialize()";    send $ORACLE "initialize()"
echo "[4] pool.initialize(...)"
send $POOL "initialize(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256)" \
  $USDC $AGUSD $SAGUSD $ORACLE $ME \
  0 $(ltv 0.04) $(ltv 0.60) $(ltv 0.80) $(ltv 0.10)

# vault: addr symbol apyBps ltv threshold bonus capUsd
wire_vault() {
  local addr=$1 sym=$2 apy=$3 l=$4 th=$5 bn=$6 cp=$7
  echo "[vault $sym] initialize"; send $addr "initialize(address,address,string)" $USDC $ORACLE "$sym"
  echo "[vault $sym] oracle.setVault nav0=1.0 rate(apy=$apy)"; send $ORACLE "setVault(address,uint256,uint256)" $addr $WAD $(rate $apy)
  echo "[vault $sym] pool.listVault"; send $POOL "listVault(address,uint256,uint256,uint256,uint256)" $addr $(ltv $l) $(ltv $th) $(ltv $bn) $(cap $cp)
}

wire_vault 0x7304966d9fa117c2b802e605051eae79fe1678f8 qPFV 1400 0.75 0.82 0.06 25000000
wire_vault 0x454f114806e60781508678ed3f8be63ebe8cadb7 qPCV 1300 0.70 0.78 0.07 10000000
wire_vault 0xa29c970ffa70eeb81d5450366528debcbd8d5628 qICV 1200 0.65 0.73 0.08 15000000
wire_vault 0xdc97675d43b5d8f5ec5353c7628f99e4825817aa tSNR  850 0.80 0.86 0.05 500000000
wire_vault 0xdcead66c3336658cb8da9bacb21e08b580b4bea6 tMEZ 1750 0.50 0.60 0.10 200000000
wire_vault 0x9468c77e0db093a3a63c991e985785d57f6b57b8 tDV  1100 0.55 0.65 0.09 300000000

echo "DONE"

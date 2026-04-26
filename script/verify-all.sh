#!/usr/bin/env bash
# Verify all 13 deployed contracts on Rayls testnet Blockscout.
# Run from repo root (smart/). Reads .env automatically via foundry.

set -e
source .env

CHAIN_ID=7295799
VERIFIER_URL='https://testnet-explorer.rayls.com/api/'
COMMON_ARGS=(
  --chain-id "$CHAIN_ID"
  --verifier blockscout
  --verifier-url "$VERIFIER_URL"
  --compiler-version 0.8.26
  --num-of-optimizations 200
  --via-ir
  --skip-is-verified-check
  --watch
)

# Constructor args precomputed via `cast abi-encode`.
DEPLOYER_ADDR=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16
USDR_ADDR=0xe52958da496cc0D3A0c652692112D5519d3bBC63
AMFI_ADDR=0xf2Db2114b62157D96a383f57De2221F8A5C00f7F
ORACLE_ADDR=0x534eC51fd74405433e1388a2907b1949BfD89D2e
FAUCET_ADDR=0x381C1F1153a1cacB8151c1e1c82E401F8E633C6d
POOL_ADDR=0x2f712E6588C54dD995295B7e34411779CcC0075e
DEBT_ADDR=0x884Cb0e601748e359B18B4c0CDafcE9E428948AF
ADAPTER_ADDR=0xF9dC483AcB3000000c5fA8F9577BCb20bC473466
SP_ADDR=0x48C5d92d50AcD644CCFAf931b98E86542Ef3B7A3
PROXY_ADDR=0x30A7321FA55904B270729d515A6D95B4AcEB9A18
SVAULT_ADDR=0x76cbf132fe4beB132e9eB35d5A0cC6450306bffc
TREASURY_ADDR=0xB74bEEe8f4b871E049082038Cc4c55d52b200A7d
RF_ADDR=0x7aDf137A51E67427404dabC35F01E92e5e910208
FEECOLLECTOR_ADDR=0x4140a587387069365688b281523Feef3f5843fd0

verify() {
    local label="$1" addr="$2" path="$3" args="$4"
    echo ""
    echo "=== Verifying $label at $addr ==="
    forge verify-contract "${COMMON_ARGS[@]}" \
        --constructor-args "$args" \
        "$addr" "$path" \
        || echo "$label failed"
}

USDR_ARGS=$(cast abi-encode "constructor(address)" $DEPLOYER_ADDR)
AMFI_ARGS=$(cast abi-encode "constructor(address,uint256)" $DEPLOYER_ADDR 160000000000000000000000000)
ORACLE_ARGS=$(cast abi-encode "constructor(address,uint256)" $DEPLOYER_ADDR 1000000000000000000)
FAUCET_ARGS=$(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256)" $DEPLOYER_ADDR $USDR_ADDR $AMFI_ADDR 1000000000000000000000000 1000000000000000000000000 86400)
DEBT_ARGS=$(cast abi-encode "constructor(address,address,string,string,uint8)" $POOL_ADDR $USDR_ADDR "Agama Debt mUSDr" "agDEBT-mUSDr" 18)
ADAPTER_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256,uint256)" $POOL_ADDR $AMFI_ADDR $ORACLE_ADDR $DEPLOYER_ADDR 7000 8000 500 86400)
SP_ARGS=$(cast abi-encode "constructor(address,address)" $POOL_ADDR $DEPLOYER_ADDR)
PROXY_ARGS=$(cast abi-encode "constructor(address,address,address)" $POOL_ADDR $SP_ADDR $DEPLOYER_ADDR)
TREASURY_ARGS=$(cast abi-encode "constructor(address,address,address,address)" $DEPLOYER_ADDR $POOL_ADDR $SP_ADDR $USDR_ADDR)
RF_ARGS=$(cast abi-encode "constructor(address,address,address,address)" $DEPLOYER_ADDR $POOL_ADDR $SP_ADDR $USDR_ADDR)
FC_ARGS=$(cast abi-encode "constructor(address,address)" $DEPLOYER_ADDR $TREASURY_ADDR)
SVAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" $DEPLOYER_ADDR $SP_ADDR $POOL_ADDR $TREASURY_ADDR $USDR_ADDR)
POOL_ARGS=$(cast abi-encode "constructor(address,address,string,string,(uint256,uint256,uint256,uint256),bool)" \
    $USDR_ADDR $DEPLOYER_ADDR "Agama Pool USDr" agUSDr \
    '(20000000000000000000000000,80000000000000000000000000,600000000000000000000000000,800000000000000000000000000)' true)

verify USDr            $USDR_ADDR         src/mocks/MockUSDr.sol:MockUSDr             "$USDR_ARGS"
verify MockAMFI        $AMFI_ADDR         src/mocks/MockAMFI.sol:MockAMFI             "$AMFI_ARGS"
verify MockOracle      $ORACLE_ADDR       src/mocks/MockOracle.sol:MockOracle         "$ORACLE_ARGS"
verify DemoFaucet      $FAUCET_ADDR       src/mocks/DemoFaucet.sol:DemoFaucet         "$FAUCET_ARGS"
verify LendingPool     $POOL_ADDR         src/core/LendingPool.sol:AgamaLendingPool   "$POOL_ARGS"
verify DebtToken       $DEBT_ADDR         src/core/DebtToken.sol:DebtToken            "$DEBT_ARGS"
verify AmFiAdapter     $ADAPTER_ADDR      src/adapters/AmFiAdapter.sol:AmFiAdapter    "$ADAPTER_ARGS"
verify StabilityPool   $SP_ADDR           src/core/StabilityPool.sol:AgamaStabilityPool "$SP_ARGS"
verify LiquidationProxy $PROXY_ADDR       src/core/LiquidationProxy.sol:LiquidationProxy "$PROXY_ARGS"
verify Treasury        $TREASURY_ADDR     src/collectors/Treasury.sol:AgamaTreasury   "$TREASURY_ARGS"
verify ReserveFund     $RF_ADDR           src/collectors/ReserveFund.sol:AgamaReserveFund "$RF_ARGS"
verify FeeCollector    $FEECOLLECTOR_ADDR src/collectors/FeeCollector.sol:AgamaFeeCollector "$FC_ARGS"
verify SettlementVault $SVAULT_ADDR       src/core/SettlementVault.sol:AgamaSettlementVault "$SVAULT_ARGS"

echo ""
echo "=== All verifications submitted ==="

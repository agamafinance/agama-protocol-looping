#!/usr/bin/env bash
# Verify all V2 deployed contracts on Rayls testnet Blockscout.
# Reads addresses from deployments/7295799.json + 7295799.tranches.json.
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

DEPLOYER_ADDR=0xf6d3C9Ed2115A5197F96f6189F6D63B51022Fe16

USDR_ADDR=$(jq -r '.contracts.USDr' deployments/7295799.json)
AMFI_ADDR=$(jq -r '.contracts.MockAMFI' deployments/7295799.json)
ORACLE_ADDR=$(jq -r '.contracts.MockOracle' deployments/7295799.json)
FAUCET_ADDR=$(jq -r '.contracts.Faucet' deployments/7295799.json)
POOL_ADDR=$(jq -r '.contracts.LendingPool' deployments/7295799.json)
DEBT_ADDR=$(jq -r '.contracts.DebtToken' deployments/7295799.json)
ADAPTER_ADDR=$(jq -r '.contracts.AmFiAdapter' deployments/7295799.json)
SP_ADDR=$(jq -r '.contracts.StabilityPool' deployments/7295799.json)
PROXY_ADDR=$(jq -r '.contracts.LiquidationProxy' deployments/7295799.json)
SVAULT_ADDR=$(jq -r '.contracts.SettlementVault' deployments/7295799.json)
TREASURY_ADDR=$(jq -r '.contracts.Treasury' deployments/7295799.json)
RF_ADDR=$(jq -r '.contracts.ReserveFund' deployments/7295799.json)
FEECOLLECTOR_ADDR=$(jq -r '.contracts.FeeCollector' deployments/7295799.json)

verify() {
    local label="$1" addr="$2" path="$3" args="$4"
    echo "=== Verifying $label at $addr ==="
    forge verify-contract "${COMMON_ARGS[@]}" \
        --constructor-args "$args" \
        "$addr" "$path" || echo "$label failed (already verified or transient)"
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
    $USDR_ADDR $DEPLOYER_ADDR "Agama Yield" agYLD \
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

# ---- Tranches (3 contracts × 6 tranches = 18) ------------------------
verify_tranche() {
    local sym="$1"
    local name=$(jq -r ".$sym.name" deployments/7295799.tranches.json)
    local apr=$(jq -r ".$sym.aprRay" deployments/7295799.tranches.json)
    local lt=$(jq -r ".$sym.lt" deployments/7295799.tranches.json)
    local maxLtv=$(jq -r ".$sym.maxLtv" deployments/7295799.tranches.json)
    local bonus=$(jq -r ".$sym.bonus" deployments/7295799.tranches.json)
    local ttype=$(jq -r ".$sym.tranche" deployments/7295799.tranches.json)
    local pool_name=$(jq -r ".$sym.pool" deployments/7295799.tranches.json)
    local token=$(jq -r ".$sym.token" deployments/7295799.tranches.json)
    local oracle=$(jq -r ".$sym.oracle" deployments/7295799.tranches.json)
    local adapter=$(jq -r ".$sym.adapter" deployments/7295799.tranches.json)

    local TOKEN_ARGS=$(cast abi-encode "constructor(string,string,string,string,uint256,address)" \
        "$name" "$sym" "$pool_name" "$ttype" "$apr" $DEPLOYER_ADDR)
    verify "${sym}_TOKEN" $token src/mocks/MockTrancheToken.sol:MockTrancheToken "$TOKEN_ARGS"

    verify "${sym}_ORACLE" $oracle src/mocks/MockOracle.sol:MockOracle "$ORACLE_ARGS"

    local AD_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256,uint256)" \
        $POOL_ADDR $token $oracle $DEPLOYER_ADDR $maxLtv $lt $bonus 86400)
    verify "${sym}_ADAPTER" $adapter src/adapters/AmFiAdapter.sol:AmFiAdapter "$AD_ARGS"
}

for sym in sRESOLV jRESOLV sDIGCAP jDIGCAP sCONDO jCONDO; do
    verify_tranche "$sym"
done

echo ""
echo "=== All verifications submitted (31 contracts) ==="

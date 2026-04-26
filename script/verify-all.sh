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
USDR_ADDR=0xF2e739F9cA47b075CB836511A65bAf353DDFe067
AMFI_ADDR=0x78e0AB3F406E7FF1929623e0C344993d93873361
ORACLE_ADDR=0x8cD52AF147Caf8EeC24f0111a86C440DD33FB330
FAUCET_ADDR=0x520D9c689B575F823BB9E2211C4559ff6280D4fE
POOL_ADDR=0x92D96b8cC443B81fBBB8a32358FD445Dd8488973
DEBT_ADDR=0x163BA7E3750d86046eb12F66802D1073451c1f1E
ADAPTER_ADDR=0x40CB409DE1f7F81CeBFdaf26053fff44018Df91b
SP_ADDR=0x6B454ACEC8B621F62B6447b94003Aa2dD44dC440
PROXY_ADDR=0xfe6De4e644019d68357d8A23f08B4FAfB119e84F
SVAULT_ADDR=0xF0062D959B82541b811f79599536D35447CC7e75
TREASURY_ADDR=0x23cCA7B1E4b2afB651CFBcfb0AC6cEB3259770d8
RF_ADDR=0x53c71f7520E4f389a85b586a4E638B26F106EA46
FEECOLLECTOR_ADDR=0xE9B615b94F2F58ee14648f684C279cAf8057516B

verify() {
    local label="$1" addr="$2" path="$3" args="$4"
    echo ""
    echo "=== Verifying $label at $addr ==="
    forge verify-contract "${COMMON_ARGS[@]}" \
        --constructor-args "$args" \
        "$addr" "$path" \
        || echo "❌ $label failed"
}

USDR_ARGS=$(cast abi-encode "constructor(address)" $DEPLOYER_ADDR)
AMFI_ARGS=$(cast abi-encode "constructor(address,uint256)" $DEPLOYER_ADDR 160000000000000000000000000)
ORACLE_ARGS=$(cast abi-encode "constructor(address,uint256)" $DEPLOYER_ADDR 1000000000000000000)
FAUCET_ARGS=$(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256)" $DEPLOYER_ADDR $USDR_ADDR $AMFI_ADDR 1000000000000000000000000 1000000000000000000000000 86400)
DEBT_ARGS=$(cast abi-encode "constructor(address,address,string,string,uint8)" $POOL_ADDR $USDR_ADDR "Agama Debt mUSDr" "agDEBT-mUSDr" 18)
ADAPTER_ARGS=$(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256,uint256)" $POOL_ADDR $AMFI_ADDR $ORACLE_ADDR $DEPLOYER_ADDR 7000 8000 500 86400)
SP_ARGS=$(cast abi-encode "constructor(address,address,bool)" $POOL_ADDR $DEPLOYER_ADDR true)
PROXY_ARGS=$(cast abi-encode "constructor(address,address,address)" $POOL_ADDR $SP_ADDR $DEPLOYER_ADDR)
TREASURY_ARGS=$(cast abi-encode "constructor(address,address,address,address,bool)" $DEPLOYER_ADDR $POOL_ADDR $SP_ADDR $USDR_ADDR true)
RF_ARGS=$(cast abi-encode "constructor(address,address,address,address)" $DEPLOYER_ADDR $POOL_ADDR $SP_ADDR $USDR_ADDR)
FC_ARGS=$(cast abi-encode "constructor(address,address)" $DEPLOYER_ADDR $TREASURY_ADDR)
SVAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,bool)" $DEPLOYER_ADDR $SP_ADDR $POOL_ADDR $TREASURY_ADDR $USDR_ADDR true)
POOL_ARGS=$(cast abi-encode "constructor(address,address,string,string,(uint256,uint256,uint256,uint256),bool)" \
    $USDR_ADDR $DEPLOYER_ADDR "Agama Pool USDr" agUSDr \
    '(20000000000000000000000000,80000000000000000000000000,600000000000000000000000000,800000000000000000000000000)' true)

verify USDr            $USDR_ADDR         src/mocks/MockUSDr.sol:MockUSDr             "$USDR_ARGS"
verify MockAMFI        $AMFI_ADDR         src/mocks/MockAMFI.sol:MockAMFI             "$AMFI_ARGS"
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

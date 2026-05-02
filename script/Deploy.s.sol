// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {DemoFaucet} from "src/mocks/DemoFaucet.sol";
import {SplitFaucet} from "src/mocks/SplitFaucet.sol";
import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaSettlementVault} from "src/core/SettlementVault.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {AgamaTreasury} from "src/collectors/Treasury.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";
import {AgamaFeeCollector} from "src/collectors/FeeCollector.sol";
import {IAgamaPool, IAgamaSP, ITreasuryDeposit} from "src/interfaces/IAgamaCollectors.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title Deploy
/// @notice One-shot deploy script for the Agama V1 stack on Rayls testnet
///         (chainId 7295799). Deploys 13 contracts, wires every role, and
///         dumps `deployments/<chainId>.json` for consumption by the
///         frontend.
/// @dev    Run dry-run with:
///             forge script script/Deploy.s.sol --rpc-url $RAYLS_TESTNET_RPC
///         Broadcast with:
///             forge script script/Deploy.s.sol --rpc-url $RAYLS_TESTNET_RPC --broadcast
contract Deploy is Script {
    // ---- V1 production parameters (identical mainnet/testnet) ------------

    uint256 internal constant AMFI_APR = 0.16e27; // 16% APR on the mock AMFI pricePerShare
    uint256 internal constant ORACLE_INITIAL = 1e18; // 1.0 USD per AMFI share at par

    uint256 internal constant MAX_LTV = 7000;
    uint256 internal constant LIQUIDATION_THRESHOLD = 8000;
    uint256 internal constant LIQUIDATION_BONUS = 500;
    uint256 internal constant ORACLE_STALENESS_MAX = 24 hours;

    uint256 internal constant FAUCET_USDR_DRIP = 1_000_000e18;
    uint256 internal constant FAUCET_AMFI_DRIP = 1_000_000e18;
    uint256 internal constant FAUCET_COOLDOWN = 24 hours;

    /// @notice Set to true on testnet, false on mainnet. Locked at deploy.
    ///         Gates ONLY `LP.fastForwardInterest`. Every other risk
    ///         parameter is identical between testnet and mainnet.
    bool internal constant TESTNET_MODE = true;

    // ---- Result struct (returned for testability + consumed by addresses.json) ----

    struct DeployedAddresses {
        address usdr;
        address amfi;
        address oracle;
        address faucet;
        address splitFaucet;
        address pool;
        address debtToken;
        address adapter;
        address sp;
        address liquidationProxy;
        address settlementVault;
        address treasury;
        address reserveFund;
        address feeCollector;
    }

    function run() external returns (DeployedAddresses memory addrs) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(pk);

        // ---- 1. Mocks ---------------------------------------------------
        MockUSDr usdr = new MockUSDr(deployer);
        MockAMFI amfi = new MockAMFI(deployer, AMFI_APR);
        MockOracle oracle = new MockOracle(deployer, ORACLE_INITIAL);
        DemoFaucet faucet =
            new DemoFaucet(deployer, usdr, amfi, FAUCET_USDR_DRIP, FAUCET_AMFI_DRIP, FAUCET_COOLDOWN);

        // The mocks expose a public unrestricted mint() — anyone can self-mint
        // test tokens, including this faucet contract. No grantRole needed.
        SplitFaucet splitFaucet = new SplitFaucet(deployer, usdr, amfi, FAUCET_USDR_DRIP, FAUCET_AMFI_DRIP, 0);

        // ---- 2. LendingPool (deploys DebtToken in its constructor) -----
        AgamaLendingPool pool = new AgamaLendingPool(
            IERC20(address(usdr)), deployer, "Agama Yield", "agYLD", IRM.defaults(), TESTNET_MODE
        );
        DebtToken debt = pool.DEBT_TOKEN();

        // ---- 3. AmFiAdapter --------------------------------------------
        AmFiAdapter adapter = new AmFiAdapter(
            address(pool),
            amfi,
            oracle,
            deployer,
            MAX_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATION_BONUS,
            ORACLE_STALENESS_MAX
        );

        // ---- 4. StabilityPool -------------------------------------------
        AgamaStabilityPool sp = new AgamaStabilityPool(IERC20(address(pool)), deployer);

        // ---- 5. LiquidationProxy ---------------------------------------
        LiquidationProxy proxy = new LiquidationProxy(pool, sp, deployer);

        // ---- 6. Collectors ---------------------------------------------
        AgamaTreasury treasury = new AgamaTreasury(
            deployer, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        AgamaReserveFund rf = new AgamaReserveFund(
            deployer, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        AgamaFeeCollector feeCollector = new AgamaFeeCollector(deployer, ITreasuryDeposit(address(treasury)));

        // ---- 7. SettlementVault ----------------------------------------
        AgamaSettlementVault svault = new AgamaSettlementVault(
            deployer,
            address(sp),
            IAgamaPool(address(pool)),
            ITreasuryDeposit(address(treasury)),
            IERC20(address(usdr))
        );

        // ---- 8. Wire roles ---------------------------------------------
        // LP-side
        pool.registerAdapter(address(adapter), true);
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        pool.setFeeRecipient(address(feeCollector));
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));

        // SP-side
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);

        // Collectors plumbing
        feeCollector.grantPool(address(pool));
        treasury.grantDepositor(address(feeCollector));
        treasury.grantDepositor(address(svault));
        rf.grantDepositor(address(svault));

        // Manager registry — deployer is the V1 manager keeper for the demo
        proxy.setManager(deployer, true);
        svault.grantManager(deployer);

        vm.stopBroadcast();

        // ---- 9. Pack & emit -------------------------------------------
        addrs = DeployedAddresses({
            usdr: address(usdr),
            amfi: address(amfi),
            oracle: address(oracle),
            faucet: address(faucet),
            splitFaucet: address(splitFaucet),
            pool: address(pool),
            debtToken: address(debt),
            adapter: address(adapter),
            sp: address(sp),
            liquidationProxy: address(proxy),
            settlementVault: address(svault),
            treasury: address(treasury),
            reserveFund: address(rf),
            feeCollector: address(feeCollector)
        });

        _log(addrs);
        _writeAddressesJson(addrs);
    }

    // ---- Helpers ---------------------------------------------------------

    function _log(DeployedAddresses memory a) internal pure {
        console.log("=== Agama V1 deployed ===");
        console.log("MockUSDr         ", a.usdr);
        console.log("MockAMFI         ", a.amfi);
        console.log("MockOracle       ", a.oracle);
        console.log("DemoFaucet       ", a.faucet);
        console.log("SplitFaucet      ", a.splitFaucet);
        console.log("LendingPool      ", a.pool);
        console.log("DebtToken        ", a.debtToken);
        console.log("AmFiAdapter      ", a.adapter);
        console.log("StabilityPool    ", a.sp);
        console.log("LiquidationProxy ", a.liquidationProxy);
        console.log("SettlementVault  ", a.settlementVault);
        console.log("Treasury         ", a.treasury);
        console.log("ReserveFund      ", a.reserveFund);
        console.log("FeeCollector     ", a.feeCollector);
    }

    function _writeAddressesJson(DeployedAddresses memory a) internal {
        // Build the contracts object first
        string memory c = "contracts";
        vm.serializeAddress(c, "USDr", a.usdr);
        vm.serializeAddress(c, "MockAMFI", a.amfi);
        vm.serializeAddress(c, "MockOracle", a.oracle);
        vm.serializeAddress(c, "Faucet", a.faucet);
        vm.serializeAddress(c, "SplitFaucet", a.splitFaucet);
        vm.serializeAddress(c, "LendingPool", a.pool);
        vm.serializeAddress(c, "DebtToken", a.debtToken);
        vm.serializeAddress(c, "AmFiAdapter", a.adapter);
        vm.serializeAddress(c, "StabilityPool", a.sp);
        vm.serializeAddress(c, "LiquidationProxy", a.liquidationProxy);
        vm.serializeAddress(c, "SettlementVault", a.settlementVault);
        vm.serializeAddress(c, "Treasury", a.treasury);
        vm.serializeAddress(c, "ReserveFund", a.reserveFund);
        string memory contractsJson = vm.serializeAddress(c, "FeeCollector", a.feeCollector);

        // Build the params object
        string memory p = "params";
        vm.serializeBool(p, "testnetMode", TESTNET_MODE);
        vm.serializeUint(p, "maxLTV", MAX_LTV);
        vm.serializeUint(p, "liquidationThreshold", LIQUIDATION_THRESHOLD);
        vm.serializeUint(p, "liquidationBonus", LIQUIDATION_BONUS);
        vm.serializeUint(p, "originationFee", 50);
        string memory paramsJson = vm.serializeUint(p, "reserveFactor", 1000);

        // Compose the top-level object
        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployedAt", block.timestamp);
        vm.serializeString(root, "contracts", contractsJson);
        string memory finalJson = vm.serializeString(root, "params", paramsJson);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, path);
        console.log("Addresses written to", path);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaSettlementVault} from "src/core/SettlementVault.sol";
import {AgamaTreasury} from "src/collectors/Treasury.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";
import {AgamaFeeCollector} from "src/collectors/FeeCollector.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {IAgamaPool, IAgamaSP, ITreasuryDeposit} from "src/interfaces/IAgamaCollectors.sol";

/// @title RedeployCollectors
/// @notice Redeploys ReserveFund + Treasury + SettlementVault to align live
///         bytecode with the post-bug-fix source. Re-wires LP / SP /
///         FeeCollector to the new addresses, then re-seeds the new RF with
///         100k USDr.
/// @dev    Old contracts keep their orphaned agaSP balances (recoverable via
///         their respective withdrawToAddress functions). For a testnet demo
///         that's acceptable.
contract RedeployCollectors is Script {
    uint256 internal constant RF_SEED = 100_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address usdrAddr = vm.parseJsonAddress(json, ".contracts.USDr");
        address poolAddr = vm.parseJsonAddress(json, ".contracts.LendingPool");
        address spAddr = vm.parseJsonAddress(json, ".contracts.StabilityPool");
        address proxyAddr = vm.parseJsonAddress(json, ".contracts.LiquidationProxy");
        address feeCollAddr = vm.parseJsonAddress(json, ".contracts.FeeCollector");

        MockUSDr usdr = MockUSDr(usdrAddr);
        AgamaLendingPool pool = AgamaLendingPool(poolAddr);
        AgamaStabilityPool sp = AgamaStabilityPool(spAddr);
        AgamaFeeCollector feeCollector = AgamaFeeCollector(feeCollAddr);

        console.log("=== RedeployCollectors ===");
        console.log("Deployer:", deployer);
        console.log("LP      :", poolAddr);
        console.log("SP      :", spAddr);

        vm.startBroadcast(pk);

        // 1. Deploy new collectors.
        AgamaTreasury newTreasury =
            new AgamaTreasury(deployer, IAgamaPool(poolAddr), IAgamaSP(spAddr), IERC20(usdrAddr));
        AgamaReserveFund newRF =
            new AgamaReserveFund(deployer, IAgamaPool(poolAddr), IAgamaSP(spAddr), IERC20(usdrAddr));
        AgamaSettlementVault newSVault = new AgamaSettlementVault(
            deployer, spAddr, IAgamaPool(poolAddr), ITreasuryDeposit(address(newTreasury)), IERC20(usdrAddr)
        );

        // 2. Re-wire references on existing infra.
        pool.setSettlementVault(address(newSVault));
        sp.setSettlementVault(address(newSVault));
        feeCollector.setTreasury(ITreasuryDeposit(address(newTreasury)));

        // 3. Grant the new SVault as depositor on the new Treasury (so settle
        //    proceeds can flow). And grant admin as manager on new SVault.
        newTreasury.grantDepositor(address(newSVault));
        newSVault.grantManager(deployer);

        // 4. Re-grant the proxy as MANAGER on SP (SP's setManager is per-account).
        sp.setManager(proxyAddr, true);

        // 5. Re-seed the new RF with 100k USDr from admin.
        usdr.mint(deployer, RF_SEED);
        usdr.approve(address(newRF), RF_SEED);
        newRF.seed(RF_SEED);

        vm.stopBroadcast();

        // ---- Verification ----
        console.log("");
        console.log("=== New addresses ===");
        console.log("Treasury (new)        :", address(newTreasury));
        console.log("ReserveFund (new)     :", address(newRF));
        console.log("SettlementVault (new) :", address(newSVault));
        console.log("");
        console.log("=== Wiring ===");
        console.log("LP.settlementVault      :", pool.settlementVault());
        console.log("SP.settlementVault      :", sp.settlementVault());
        console.log("FeeCollector.treasury   :", address(feeCollector.treasury()));
        console.log("New SVault TREASURY     :", address(newSVault.TREASURY()));
        console.log("New RF coverage         :", newRF.coverageBalance());
        console.log("New Treasury agaSP      :", IERC20(spAddr).balanceOf(address(newTreasury)));
    }
}

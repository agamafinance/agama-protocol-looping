// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaSettlementVault} from "src/core/SettlementVault.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";

/// @title DemoSetup
/// @notice Post-deploy setup: seeds the ReserveFund with 100k USDr at TGE
///         (the Rayls grant simulation), which auto-stakes into the SP, and
///         verifies the wiring with a battery of view calls.
/// @dev    Reads contract addresses from `deployments/<chainId>.json`. Run
///         after `Deploy.s.sol` has broadcast.
contract DemoSetup is Script {
    uint256 internal constant RF_SEED = 100_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address usdrAddr = vm.parseJsonAddress(json, ".contracts.USDr");
        address poolAddr = vm.parseJsonAddress(json, ".contracts.LendingPool");
        address spAddr = vm.parseJsonAddress(json, ".contracts.StabilityPool");
        address rfAddr = vm.parseJsonAddress(json, ".contracts.ReserveFund");
        address svaultAddr = vm.parseJsonAddress(json, ".contracts.SettlementVault");

        MockUSDr usdr = MockUSDr(usdrAddr);
        AgamaLendingPool pool = AgamaLendingPool(poolAddr);
        AgamaStabilityPool sp = AgamaStabilityPool(spAddr);
        AgamaReserveFund rf = AgamaReserveFund(rfAddr);
        AgamaSettlementVault svault = AgamaSettlementVault(svaultAddr);

        console.log("=== DemoSetup ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // ---- 1. Mint the RF seed USDr to deployer (admin holds MINTER_ROLE) ----
        usdr.mint(deployer, RF_SEED);

        // ---- 2. Approve RF, then seed → auto-stakes into SP ----
        usdr.approve(address(rf), RF_SEED);
        rf.seed(RF_SEED);

        vm.stopBroadcast();

        // ---- 3. Verification view calls ----
        console.log("");
        console.log("=== Verification ===");
        console.log("LP testnetMode            ", pool.testnetMode());
        console.log("LP totalAssets()          ", pool.totalAssets());
        console.log("LP totalSupply()          ", pool.totalSupply());
        console.log("SP totalAssets()          ", sp.totalAssets());
        console.log("SP totalSupply()          ", sp.totalSupply());
        console.log("RF coverageBalance (agaSP)", rf.coverageBalance());
        console.log("LP feeRecipient           ", pool.feeRecipient());
        console.log("LP stabilityPool          ", pool.stabilityPool());
        console.log("LP settlementVault        ", pool.settlementVault());
        console.log("SP settlementVault        ", sp.settlementVault());
        console.log("Vault staleBatchPeriod    ", svault.staleBatchPeriod());
        console.log("Vault pegGapPendingForSP  ", svault.pegGapPendingForSP());
        // No grace period — instant liquidation when HF < 1.
        // No SP withdraw timelock — direct ERC-4626 redeem.
        console.log("");
        console.log("If LP totalAssets == 100_000e18 and SP totalAssets == 100_000e18,");
        console.log("the RF seed flowed through correctly.");
    }
}

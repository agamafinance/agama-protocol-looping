// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {IPricedToken} from "src/interfaces/IPricedToken.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {MockTrancheToken} from "src/mocks/MockTrancheToken.sol";

/// @title DeployTranches
/// @notice Delta-deploy that adds the 6 AmFi-style tranches to an existing
///         Agama V1 deployment (LP/SP/Vault/etc unchanged). For each
///         tranche we deploy:
///           - one MockTrancheToken (the yield-bearing collateral mock)
///           - one MockOracle (USD price feed, 1.0 at par)
///           - one AmFiAdapter wired to (LP, token, oracle, risk params)
///         then register the adapter on the LP.
///
///         Senior tranches use safer risk params (LTV 75 / LT 85 / Bonus 3)
///         and a 12% target APY (mirroring AmFi's senior cap). Junior
///         tranches use riskier params (LTV 50 / LT 65 / Bonus 8) and a
///         24% mock APY (uncapped overflow yield in real AmFi).
contract DeployTranches is Script {
    // ---- Risk profiles ---------------------------------------------------

    uint256 internal constant SENIOR_APR = 0.12e27; // 12% — capped target
    uint256 internal constant JUNIOR_APR = 0.24e27; // 24% — uncapped overflow

    uint256 internal constant SENIOR_LTV = 7500; // 75%
    uint256 internal constant SENIOR_LT = 8500; // 85%
    uint256 internal constant SENIOR_BONUS = 300; // 3%

    uint256 internal constant JUNIOR_LTV = 5000; // 50%
    uint256 internal constant JUNIOR_LT = 6500; // 65%
    uint256 internal constant JUNIOR_BONUS = 800; // 8%

    uint256 internal constant ORACLE_INITIAL = 1e18; // 1 USD per share at par
    uint256 internal constant ORACLE_STALENESS_MAX = 24 hours;

    // ---- Tranche definitions --------------------------------------------

    struct TrancheSpec {
        string name;
        string symbol;
        string poolName;
        string trancheType; // "Senior" | "Junior"
        uint256 aprRay;
        uint256 maxLtv;
        uint256 lt;
        uint256 bonus;
    }

    struct DeployedTranche {
        address token;
        address oracle;
        address adapter;
    }

    function _specs() internal pure returns (TrancheSpec[6] memory s) {
        s[0] = TrancheSpec(
            "Resolvi Senior", "sRESOLV", "Resolvi", "Senior", SENIOR_APR, SENIOR_LTV, SENIOR_LT, SENIOR_BONUS
        );
        s[1] = TrancheSpec(
            "Resolvi Junior", "jRESOLV", "Resolvi", "Junior", JUNIOR_APR, JUNIOR_LTV, JUNIOR_LT, JUNIOR_BONUS
        );
        s[2] = TrancheSpec(
            "Digcap Senior", "sDIGCAP", "Digcap", "Senior", SENIOR_APR, SENIOR_LTV, SENIOR_LT, SENIOR_BONUS
        );
        s[3] = TrancheSpec(
            "Digcap Junior", "jDIGCAP", "Digcap", "Junior", JUNIOR_APR, JUNIOR_LTV, JUNIOR_LT, JUNIOR_BONUS
        );
        s[4] = TrancheSpec(
            "Sector Condo Senior",
            "sCONDO",
            "Sector Condo",
            "Senior",
            SENIOR_APR,
            SENIOR_LTV,
            SENIOR_LT,
            SENIOR_BONUS
        );
        s[5] = TrancheSpec(
            "Sector Condo Junior",
            "jCONDO",
            "Sector Condo",
            "Junior",
            JUNIOR_APR,
            JUNIOR_LTV,
            JUNIOR_LT,
            JUNIOR_BONUS
        );
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address lpAddr = vm.parseJsonAddress(json, ".contracts.LendingPool");
        AgamaLendingPool lp = AgamaLendingPool(lpAddr);

        console.log("=== DeployTranches ===");
        console.log("Deployer  :", deployer);
        console.log("LP target :", lpAddr);

        TrancheSpec[6] memory specs = _specs();
        DeployedTranche[6] memory out;

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < specs.length; i++) {
            TrancheSpec memory sp = specs[i];

            MockTrancheToken token =
                new MockTrancheToken(sp.name, sp.symbol, sp.poolName, sp.trancheType, sp.aprRay, deployer);
            MockOracle oracle = new MockOracle(deployer, ORACLE_INITIAL);
            AmFiAdapter adapter = new AmFiAdapter(
                lpAddr,
                IPricedToken(address(token)),
                oracle,
                deployer,
                sp.maxLtv,
                sp.lt,
                sp.bonus,
                ORACLE_STALENESS_MAX
            );
            lp.registerAdapter(address(adapter), true);

            out[i] =
                DeployedTranche({token: address(token), oracle: address(oracle), adapter: address(adapter)});
        }
        vm.stopBroadcast();

        // ---- Log -------------------------------------------------------
        console.log("");
        console.log("=== 6 tranches deployed ===");
        for (uint256 i = 0; i < specs.length; i++) {
            console.log("--", specs[i].symbol, "--");
            console.log("  token   :", out[i].token);
            console.log("  oracle  :", out[i].oracle);
            console.log("  adapter :", out[i].adapter);
        }

        // ---- Persist to deployments JSON via a side-car file ----------
        // We don't rewrite the main JSON in-script (vm.serializeJson would
        // require re-emitting the whole file). Instead we write a separate
        // tranches.json that the front-end pnpm abi:extract picks up via
        // a small extra step in scripts/extract-abis.mjs.
        _writeTranchesJson(specs, out);
    }

    function _writeTranchesJson(TrancheSpec[6] memory specs, DeployedTranche[6] memory out) internal {
        string memory root = "tranches";
        for (uint256 i = 0; i < specs.length; i++) {
            string memory key = specs[i].symbol;
            vm.serializeString(key, "name", specs[i].name);
            vm.serializeString(key, "symbol", specs[i].symbol);
            vm.serializeString(key, "pool", specs[i].poolName);
            vm.serializeString(key, "tranche", specs[i].trancheType);
            vm.serializeUint(key, "aprRay", specs[i].aprRay);
            vm.serializeUint(key, "maxLtv", specs[i].maxLtv);
            vm.serializeUint(key, "lt", specs[i].lt);
            vm.serializeUint(key, "bonus", specs[i].bonus);
            vm.serializeAddress(key, "token", out[i].token);
            vm.serializeAddress(key, "oracle", out[i].oracle);
            string memory item = vm.serializeAddress(key, "adapter", out[i].adapter);
            vm.serializeString(root, key, item);
        }
        // Final flush — chained from the last serialize gives us a complete
        // JSON object for the root key.
        string memory finalJson = vm.serializeString(root, "_chainId", vm.toString(block.chainid));

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".tranches.json");
        vm.writeJson(finalJson, path);
        console.log("");
        console.log("Tranches JSON written to", path);
    }
}

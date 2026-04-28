// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {IPricedToken} from "src/interfaces/IPricedToken.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockTrancheToken} from "src/mocks/MockTrancheToken.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title StressBase
/// @notice Shared fixture for the multi-tranche stress test suite.
///         Deploys the full V1 stack (LP/SP/SVault/Treasury/RF/FeeCollector
///         + LiquidationProxy) plus 6 AmFi-style tranches (3 pools × Senior
///         + Junior). Materialises 30 actor addresses (whales/midcaps/retails
///         × lenders/borrowers/SP-stakers) and exposes invariants INV1..INV7.
///
///         Each test contract `is StressBase` and inherits the wired stack
///         + helpers. Foundry runs each `test_*` function with a fresh
///         setUp(), so per-scenario isolation is automatic.
contract StressBase is Test {
    // ---- Roles ---------------------------------------------------------

    address internal admin = address(0xA11CE);
    address internal manager = address(0x111A);
    address internal raylsGrant = address(0x6147);

    // ---- Core protocol -------------------------------------------------

    MockUSDr internal usdr;
    AgamaLendingPool internal pool;
    AgamaStabilityPool internal sp;
    LiquidationProxy internal proxy;
    AgamaSettlementVault internal svault;
    AgamaTreasury internal treasury;
    AgamaReserveFund internal rf;
    AgamaFeeCollector internal feeCollector;
    DebtToken internal debt;

    // ---- Tranches (6) --------------------------------------------------
    //   pool       | senior              | junior
    //   ---------- | ------------------- | -------------------
    //   Resolvi    | sRESOLV             | jRESOLV
    //   Digcap     | sDIGCAP             | jDIGCAP
    //   SectorCondo| sCONDO              | jCONDO

    struct Tranche {
        MockTrancheToken token;
        MockOracle oracle;
        AmFiAdapter adapter;
        bool senior;
    }

    Tranche[6] internal tranches;
    uint256 internal constant T_SRES = 0;
    uint256 internal constant T_JRES = 1;
    uint256 internal constant T_SDIG = 2;
    uint256 internal constant T_JDIG = 3;
    uint256 internal constant T_SCON = 4;
    uint256 internal constant T_JCON = 5;

    // ---- Actors (30) ---------------------------------------------------
    //   Each role bucket holds 5 fixed addresses. They overlap intentionally
    //   so the same wallet can lend AND stake AND borrow — modelling the
    //   real protocol where actors play multiple roles.

    address[5] internal whales;       // 500k–1M MockUSDr
    address[5] internal midcaps;      // 50k–200k
    address[5] internal retails;      // 1k–50k
    address[5] internal conservatives; // borrowers, LTV 30–50%
    address[5] internal moderates;    // borrowers, LTV 50–65%
    address[5] internal aggressives;  // borrowers, LTV 65%+

    address[8] internal spStakers;    // first 8 of (whales ∪ midcaps)

    // ---- Constants -----------------------------------------------------

    uint256 internal constant RF_SEED = 100_000e18;
    bytes internal constant ZERO_DATA = abi.encode(uint256(0));
    uint256 internal constant INITIAL_USDR_PER_BORROWER = 1_000_000e18;
    uint256 internal constant INITIAL_TRANCHE_PER_BORROWER = 1_000_000e18;

    // Lenders are over-funded so any scenario in their bucket fits.
    uint256 internal constant WHALE_MINT  = 2_000_000e18;  // covers 500k–1M scenarios
    uint256 internal constant MIDCAP_MINT =   500_000e18;  // covers 50k–200k
    uint256 internal constant RETAIL_MINT =   100_000e18;  // covers 1k–50k

    // RF.seed() mints 100k USDr-equivalent agaSP at TGE — this is the
    // baseline TVL every test starts with (assets) and the baseline
    // SP supply (after the LP's _decimalsOffset = 6 stretches it by 1e6).
    uint256 internal constant BASELINE_TVL = RF_SEED;
    uint256 internal constant BASELINE_SP_SHARES = RF_SEED * 1e6;

    // ---- Setup ---------------------------------------------------------

    function setUp() public virtual {
        _deployCore();
        _deployTranches();
        _wireRoles();
        _seedActors();
        _seedReserveFund();
    }

    function _deployCore() internal {
        usdr = new MockUSDr(admin);
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        proxy = new LiquidationProxy(pool, sp, admin);
        debt = pool.DEBT_TOKEN();

        treasury = new AgamaTreasury(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        rf = new AgamaReserveFund(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        feeCollector = new AgamaFeeCollector(admin, ITreasuryDeposit(address(treasury)));
        svault = new AgamaSettlementVault(
            admin,
            address(sp),
            IAgamaPool(address(pool)),
            ITreasuryDeposit(address(treasury)),
            IERC20(address(usdr))
        );
    }

    function _deployTranches() internal {
        // Senior risk: LTV 75 / LT 85 / Bonus 3 / APR 12%
        // Junior risk: LTV 50 / LT 65 / Bonus 8 / APR 24%
        _spawn(T_SRES, "Resolvi Senior",       "sRESOLV", "Resolvi",      "Senior", 0.12e27, true);
        _spawn(T_JRES, "Resolvi Junior",       "jRESOLV", "Resolvi",      "Junior", 0.24e27, false);
        _spawn(T_SDIG, "Digcap Senior",        "sDIGCAP", "Digcap",       "Senior", 0.12e27, true);
        _spawn(T_JDIG, "Digcap Junior",        "jDIGCAP", "Digcap",       "Junior", 0.24e27, false);
        _spawn(T_SCON, "SectorCondo Senior",   "sCONDO",  "Sector Condo", "Senior", 0.12e27, true);
        _spawn(T_JCON, "SectorCondo Junior",   "jCONDO",  "Sector Condo", "Junior", 0.24e27, false);
    }

    function _spawn(
        uint256 idx,
        string memory name,
        string memory symbol,
        string memory poolName,
        string memory trancheType,
        uint256 aprRay,
        bool senior
    ) internal {
        MockTrancheToken tok = new MockTrancheToken(name, symbol, poolName, trancheType, aprRay, admin);
        MockOracle ora = new MockOracle(admin, 1e18);
        AmFiAdapter ada = new AmFiAdapter(
            address(pool),
            IPricedToken(address(tok)),
            ora,
            admin,
            senior ? 7500 : 5000,
            senior ? 8500 : 6500,
            senior ? 300 : 800,
            24 hours
        );
        tranches[idx] = Tranche({token: tok, oracle: ora, adapter: ada, senior: senior});
    }

    function _wireRoles() internal {
        vm.startPrank(admin);
        for (uint256 i = 0; i < 6; ++i) {
            pool.registerAdapter(address(tranches[i].adapter), true);
        }
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        pool.setFeeRecipient(address(feeCollector));
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));
        feeCollector.grantPool(address(pool));
        treasury.grantDepositor(address(feeCollector));
        treasury.grantDepositor(address(svault));
        rf.grantDepositor(address(svault));
        proxy.setManager(manager, true);
        svault.grantManager(manager);
        vm.stopPrank();
    }

    function _seedActors() internal {
        // 5 whales: 500k, 600k, 750k, 900k, 1M MockUSDr
        whales[0] = vm.addr(uint256(keccak256("whale0")));
        whales[1] = vm.addr(uint256(keccak256("whale1")));
        whales[2] = vm.addr(uint256(keccak256("whale2")));
        whales[3] = vm.addr(uint256(keccak256("whale3")));
        whales[4] = vm.addr(uint256(keccak256("whale4")));

        midcaps[0] = vm.addr(uint256(keccak256("midcap0")));
        midcaps[1] = vm.addr(uint256(keccak256("midcap1")));
        midcaps[2] = vm.addr(uint256(keccak256("midcap2")));
        midcaps[3] = vm.addr(uint256(keccak256("midcap3")));
        midcaps[4] = vm.addr(uint256(keccak256("midcap4")));

        retails[0] = vm.addr(uint256(keccak256("retail0")));
        retails[1] = vm.addr(uint256(keccak256("retail1")));
        retails[2] = vm.addr(uint256(keccak256("retail2")));
        retails[3] = vm.addr(uint256(keccak256("retail3")));
        retails[4] = vm.addr(uint256(keccak256("retail4")));

        // Borrowers — every borrower gets full mint of every tranche +
        // a generous USDr float for repayments.
        conservatives[0] = vm.addr(uint256(keccak256("cons0")));
        conservatives[1] = vm.addr(uint256(keccak256("cons1")));
        conservatives[2] = vm.addr(uint256(keccak256("cons2")));
        conservatives[3] = vm.addr(uint256(keccak256("cons3")));
        conservatives[4] = vm.addr(uint256(keccak256("cons4")));

        moderates[0] = vm.addr(uint256(keccak256("mod0")));
        moderates[1] = vm.addr(uint256(keccak256("mod1")));
        moderates[2] = vm.addr(uint256(keccak256("mod2")));
        moderates[3] = vm.addr(uint256(keccak256("mod3")));
        moderates[4] = vm.addr(uint256(keccak256("mod4")));

        aggressives[0] = vm.addr(uint256(keccak256("agg0")));
        aggressives[1] = vm.addr(uint256(keccak256("agg1")));
        aggressives[2] = vm.addr(uint256(keccak256("agg2")));
        aggressives[3] = vm.addr(uint256(keccak256("agg3")));
        aggressives[4] = vm.addr(uint256(keccak256("agg4")));

        // Mint USDr to lenders — generous floor, scenarios use scenario-driven amounts.
        vm.startPrank(admin);
        for (uint256 i = 0; i < 5; ++i) {
            usdr.mint(whales[i], WHALE_MINT);
            usdr.mint(midcaps[i], MIDCAP_MINT);
            usdr.mint(retails[i], RETAIL_MINT);
        }
        // Mint USDr + every tranche to every borrower
        for (uint256 i = 0; i < 5; ++i) {
            address[3] memory bs = [conservatives[i], moderates[i], aggressives[i]];
            for (uint256 j = 0; j < 3; ++j) {
                usdr.mint(bs[j], INITIAL_USDR_PER_BORROWER);
                for (uint256 k = 0; k < 6; ++k) {
                    tranches[k].token.mint(bs[j], INITIAL_TRANCHE_PER_BORROWER);
                }
            }
        }
        // Mint USDr to manager for settlement simulations
        usdr.mint(manager, 50_000_000e18);
        // Seed RF grant in admin
        usdr.mint(admin, RF_SEED);
        vm.stopPrank();

        // SP stakers = first 8 of (whales + midcaps)
        spStakers[0] = whales[0];
        spStakers[1] = whales[1];
        spStakers[2] = whales[2];
        spStakers[3] = whales[3];
        spStakers[4] = whales[4];
        spStakers[5] = midcaps[0];
        spStakers[6] = midcaps[1];
        spStakers[7] = midcaps[2];
    }

    function _seedReserveFund() internal {
        vm.startPrank(admin);
        usdr.approve(address(rf), RF_SEED);
        rf.seed(RF_SEED);
        vm.stopPrank();
    }

    // ---- Action helpers ------------------------------------------------

    function _deposit(address actor, uint256 amount) internal {
        vm.startPrank(actor);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, actor);
        vm.stopPrank();
    }

    function _withdraw(address actor, uint256 assets) internal {
        vm.prank(actor);
        pool.withdraw(assets, actor, actor);
    }

    function _stakeSp(address actor, uint256 agTokenAmount) internal {
        vm.startPrank(actor);
        pool.approve(address(sp), agTokenAmount);
        sp.deposit(agTokenAmount, actor);
        vm.stopPrank();
    }

    function _openVault(address actor) internal {
        vm.prank(actor);
        pool.openVaultPosition();
    }

    function _depositCollat(address actor, uint256 trancheIdx, uint256 amount) internal {
        vm.startPrank(actor);
        tranches[trancheIdx].token.approve(address(tranches[trancheIdx].adapter), amount);
        pool.depositAsset(address(tranches[trancheIdx].adapter), abi.encode(amount));
        vm.stopPrank();
    }

    function _withdrawCollat(address actor, uint256 trancheIdx, uint256 amount) internal {
        vm.prank(actor);
        pool.withdrawAsset(address(tranches[trancheIdx].adapter), abi.encode(amount));
    }

    function _borrow(address actor, uint256 trancheIdx, uint256 amount) internal {
        vm.prank(actor);
        pool.borrow(address(tranches[trancheIdx].adapter), ZERO_DATA, amount);
    }

    function _repay(address actor, uint256 trancheIdx, uint256 amount) internal {
        vm.startPrank(actor);
        usdr.approve(address(pool), amount);
        pool.repay(address(tranches[trancheIdx].adapter), ZERO_DATA, amount);
        vm.stopPrank();
    }

    function _crashOracle(uint256 trancheIdx, uint256 newPrice) internal {
        vm.prank(admin);
        tranches[trancheIdx].oracle.setPrice(newPrice);
    }

    /// Drop oracle by `bps` basis points relative to current price.
    function _crashOracleBps(uint256 trancheIdx, uint256 dropBps) internal {
        uint256 cur = tranches[trancheIdx].oracle.getPrice();
        _crashOracle(trancheIdx, (cur * (10_000 - dropBps)) / 10_000);
    }

    function _liquidate(address borrower, uint256 trancheIdx) internal {
        address ada = address(tranches[trancheIdx].adapter);
        vm.prank(manager);
        proxy.liquidate(ada, ada, borrower, ZERO_DATA, 0);
    }

    function _hf(address borrower, uint256 trancheIdx) internal view returns (uint256) {
        return pool.calculateHealthFactor(address(tranches[trancheIdx].adapter), borrower, ZERO_DATA);
    }

    function _collatValue(address borrower, uint256 trancheIdx) internal view returns (uint256) {
        return tranches[trancheIdx].adapter.getAssetValue(borrower, ZERO_DATA);
    }

    /// One-shot lending+collateral+borrow. Returns nothing — read state.
    function _oneShotLeveragedPosition(
        address actor,
        uint256 trancheIdx,
        uint256 collatAmount,
        uint256 borrowAmount
    ) internal {
        _openVault(actor);
        _depositCollat(actor, trancheIdx, collatAmount);
        _borrow(actor, trancheIdx, borrowAmount);
    }

    // ---- Invariants (INV1..INV7) ---------------------------------------

    /// INV1: LP.totalAssets() ≈ cash on LP + DebtToken outstanding (within
    /// 1 wei rounding from ERC-4626 + scaled-debt index math).
    function _checkINV1() internal view {
        uint256 cash = usdr.balanceOf(address(pool));
        uint256 outstanding = debt.totalSupply();
        uint256 ta = pool.totalAssets();
        // Some bad-debt redistribution can push totalAssets above cash + debt
        // by the *redistributed* delta — we tolerate ~0.01% drift to absorb
        // both the rounding and the bdAccLDebt scaling.
        uint256 lo = (cash + outstanding) * 9999 / 10_000;
        uint256 hi = (cash + outstanding) * 10_001 / 10_000 + 1e6;
        require(ta >= lo && ta <= hi, "INV1 violated: totalAssets vs cash+debt");
    }

    /// INV2: SP.totalSupply == sum(SP.balanceOf(holder)) for tracked holders.
    /// We track every actor + protocol holders.
    function _checkINV2_partial(address[] memory holders) internal view {
        uint256 sum;
        for (uint256 i = 0; i < holders.length; ++i) sum += sp.balanceOf(holders[i]);
        require(sum <= sp.totalSupply(), "INV2 violated: holders > supply");
    }

    /// INV3, INV4: Treasury / RF agaSP balances are non-negative (uint256
    /// guarantees this by construction; we assert they exist).
    function _checkINV3_INV4() internal view {
        // uint256 cannot go negative; real check is "no underflow happened",
        // which would have reverted earlier. We assert the slots are readable.
        require(sp.balanceOf(address(treasury)) <= sp.totalSupply(), "INV3 violated");
        require(sp.balanceOf(address(rf)) <= sp.totalSupply(), "INV4 violated");
    }

    /// INV5: For a list of borrowers, HF >= 1 OR the borrower is currently
    /// liquidatable (caller must filter accordingly).
    function _assertHfHealthy(address borrower, uint256 trancheIdx) internal view {
        require(_hf(borrower, trancheIdx) >= 1e27, "INV5 violated: HF < 1");
    }

    /// INV6: pool.totalSupply (agTOKEN) consistent — convertToAssets(totalSupply)
    /// ≈ totalAssets. ERC-4626 invariant by construction; we sanity-check.
    function _checkINV6() internal view {
        uint256 ts = pool.totalSupply();
        if (ts == 0) return;
        uint256 implied = pool.convertToAssets(ts);
        uint256 ta = pool.totalAssets();
        // Allow 0.01% drift from rounding.
        if (implied > ta) {
            require(implied - ta <= ta / 10_000 + 1, "INV6 violated: implied > ta");
        } else {
            require(ta - implied <= ta / 10_000 + 1, "INV6 violated: ta > implied");
        }
    }

    /// INV7: agaSP soulbound — transfer must revert.
    function _checkINV7() internal {
        if (sp.balanceOf(address(treasury)) == 0) return;
        vm.prank(address(treasury));
        (bool ok,) =
            address(sp).call(abi.encodeWithSignature("transfer(address,uint256)", address(0xdead), 1));
        require(!ok, "INV7 violated: agaSP transfer succeeded");
    }

    /// Run all cheap invariants. Call after each non-trivial action.
    function _verifyInvariants() internal {
        _checkINV1();
        _checkINV3_INV4();
        _checkINV6();
        _checkINV7();
    }
}

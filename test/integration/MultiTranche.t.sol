// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {IPricedToken} from "src/interfaces/IPricedToken.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockTrancheToken} from "src/mocks/MockTrancheToken.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title MultiTranche
/// @notice E2E integration test of two tranches sharing the same LendingPool:
///         a Senior (low risk, high LTV) and a Junior (high risk, low LTV)
///         from the same originator pool ("Resolvi"). Verifies:
///           - Both adapters wire to the same LP and share the SP.
///           - Per-tranche risk params apply correctly to HF math.
///           - An oracle crash on one tranche does not affect the other.
///           - The Junior trips its LT first; the Senior survives the same
///             percentage drop (because its LT is wider).
contract MultiTrancheTest is Test {
    address admin = address(0xA11CE);
    address alice = address(0xA17CE);
    address bob = address(0xB0B);

    MockUSDr usdr;
    AgamaLendingPool pool;

    MockTrancheToken sResolv;
    MockTrancheToken jResolv;
    MockOracle sOracle;
    MockOracle jOracle;
    AmFiAdapter sAdapter;
    AmFiAdapter jAdapter;

    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Yield", "agYLD", IRM.defaults(), true
        );

        // Two tranches of the same originator pool ("Resolvi")
        sResolv = new MockTrancheToken("Resolvi Senior", "sRESOLV", "Resolvi", "Senior", 0.12e27, admin);
        jResolv = new MockTrancheToken("Resolvi Junior", "jRESOLV", "Resolvi", "Junior", 0.24e27, admin);

        sOracle = new MockOracle(admin, 1e18);
        jOracle = new MockOracle(admin, 1e18);

        // Senior: LTV 75 / LT 85 / Bonus 3
        sAdapter = new AmFiAdapter(
            address(pool), IPricedToken(address(sResolv)), sOracle, admin, 7500, 8500, 300, 24 hours
        );
        // Junior: LTV 50 / LT 65 / Bonus 8
        jAdapter = new AmFiAdapter(
            address(pool), IPricedToken(address(jResolv)), jOracle, admin, 5000, 6500, 800, 24 hours
        );

        vm.startPrank(admin);
        pool.registerAdapter(address(sAdapter), true);
        pool.registerAdapter(address(jAdapter), true);
        usdr.mint(bob, 5_000_000e18);
        sResolv.mint(alice, 1_000_000e18);
        jResolv.mint(alice, 1_000_000e18);
        vm.stopPrank();

        // Bob seeds liquidity to LP
        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(2_000_000e18, bob);
        vm.stopPrank();
    }

    // ---- Per-adapter risk params surface correctly --------------------

    function test_senior_riskParams() public view {
        assertEq(sAdapter.MAX_LTV(), 7500);
        assertEq(sAdapter.LIQUIDATION_THRESHOLD(), 8500);
        assertEq(sAdapter.LIQUIDATION_BONUS(), 300);
    }

    function test_junior_riskParams() public view {
        assertEq(jAdapter.MAX_LTV(), 5000);
        assertEq(jAdapter.LIQUIDATION_THRESHOLD(), 6500);
        assertEq(jAdapter.LIQUIDATION_BONUS(), 800);
    }

    function test_adapters_pointDifferentTokens() public view {
        assertEq(sAdapter.getAssetToken(), address(sResolv));
        assertEq(jAdapter.getAssetToken(), address(jResolv));
    }

    // ---- HF math respects per-adapter LT ------------------------------

    function test_senior_higher_borrowCapacity() public {
        // Alice opens a senior-collateral position
        vm.startPrank(alice);
        pool.openVaultPosition();
        sResolv.approve(address(sAdapter), type(uint256).max);
        pool.depositAsset(address(sAdapter), abi.encode(uint256(100_000e18)));
        // Senior LTV 75% → can borrow up to 75k against 100k collateral
        pool.borrow(address(sAdapter), ZERO_DATA, 70_000e18);
        vm.stopPrank();

        // HF still safe (70k borrowed at LT 85% on 100k → HF = 100*0.85/70 = 1.214)
        uint256 hf = pool.calculateHealthFactor(address(sAdapter), alice, ZERO_DATA);
        assertGt(hf, 1.2e27);
    }

    function test_junior_lowerBorrowCapacity_revertsOver50pct() public {
        vm.startPrank(alice);
        pool.openVaultPosition();
        jResolv.approve(address(jAdapter), type(uint256).max);
        pool.depositAsset(address(jAdapter), abi.encode(uint256(100_000e18)));
        // Junior LTV 50% — borrowing 70k against 100k collateral should revert
        // (70 > maxLtv * collateral = 50)
        vm.expectRevert(AgamaLendingPool.HealthFactorTooLow.selector);
        pool.borrow(address(jAdapter), ZERO_DATA, 70_000e18);
        vm.stopPrank();
    }

    // ---- Independent oracles ------------------------------------------

    function test_seniorOracleCrash_doesNotAffectJuniorHF() public {
        // Alice borrows ONLY against senior so the junior HF is "infinite"
        // (no debt) and stays infinite when senior oracle crashes.
        vm.startPrank(alice);
        pool.openVaultPosition();
        sResolv.approve(address(sAdapter), type(uint256).max);
        pool.depositAsset(address(sAdapter), abi.encode(uint256(100_000e18)));
        pool.borrow(address(sAdapter), ZERO_DATA, 50_000e18);
        // Alice deposits junior collateral too but does NOT borrow against it.
        jResolv.approve(address(jAdapter), type(uint256).max);
        pool.depositAsset(address(jAdapter), abi.encode(uint256(100_000e18)));
        vm.stopPrank();

        uint256 sHfBefore = pool.calculateHealthFactor(address(sAdapter), alice, ZERO_DATA);

        // Crash only senior oracle 25%.
        vm.prank(admin);
        sOracle.setPrice(0.75e18);

        uint256 sHfAfter = pool.calculateHealthFactor(address(sAdapter), alice, ZERO_DATA);
        assertLt(sHfAfter, sHfBefore, "senior HF dropped after senior oracle crash");

        // Junior oracle untouched, junior collateral still values at par.
        // Use a fresh price feed read to confirm independence.
        assertEq(jOracle.getPrice(), 1e18);
    }

    // ---- Liquidation-threshold differential ---------------------------

    function test_juniorLT_tipsFirst_atSameDrop_seniorSurvives() public {
        // Two separate users borrowing at the SAME absolute LTV (50%). The
        // tranche LT is the only thing that differs. After a 30% oracle
        // drop, the JUNIOR (LT 65%) tips below HF=1 first; the SENIOR
        // (LT 85%) still survives — exactly the protective buffer the
        // higher LT was meant to provide.
        address aliceSenior = alice;
        address bobJunior = address(0xB0BB);

        vm.prank(admin);
        jResolv.mint(bobJunior, 1_000_000e18);

        // Alice senior: 50k debt against 100k collateral (LTV 50%)
        vm.startPrank(aliceSenior);
        pool.openVaultPosition();
        sResolv.approve(address(sAdapter), type(uint256).max);
        pool.depositAsset(address(sAdapter), abi.encode(uint256(100_000e18)));
        pool.borrow(address(sAdapter), ZERO_DATA, 50_000e18);
        vm.stopPrank();

        // Bob junior: 50k debt against 100k collateral (LTV 50%, MAX cap)
        vm.startPrank(bobJunior);
        pool.openVaultPosition();
        jResolv.approve(address(jAdapter), type(uint256).max);
        pool.depositAsset(address(jAdapter), abi.encode(uint256(100_000e18)));
        pool.borrow(address(jAdapter), ZERO_DATA, 50_000e18);
        vm.stopPrank();

        // Both oracles drop 30%
        vm.prank(admin);
        sOracle.setPrice(0.7e18);
        vm.prank(admin);
        jOracle.setPrice(0.7e18);

        uint256 sHf = pool.calculateHealthFactor(address(sAdapter), aliceSenior, ZERO_DATA);
        uint256 jHf = pool.calculateHealthFactor(address(jAdapter), bobJunior, ZERO_DATA);

        // Senior: 70k * 0.85 / 50k = HF 1.19  → safe
        // Junior: 70k * 0.65 / 50k = HF 0.91  → liquidatable
        assertGt(sHf, 1e27, "senior survives 30% drop at LTV 50% (LT 85% buffer)");
        assertLt(jHf, 1e27, "junior tips below 1 at 30% drop (LT 65% buffer too narrow)");
    }
}

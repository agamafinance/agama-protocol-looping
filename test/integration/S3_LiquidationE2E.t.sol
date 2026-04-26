// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {MockSettlementVault} from "src/mocks/MockSettlementVault.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S3_LiquidationE2E
/// @notice End-to-end exercise of the liquidation pipeline: oracle drop →
///         initiate (HF<1) → grace period → finalize → SP absorbs → bonus
///         settle. Also covers the bad-debt redistribution path when SP
///         capacity is insufficient.
contract S3LiquidationE2ETest is Test {
    address admin = address(0xA11CE);
    address manager = address(0x111A);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);
    address charlie = address(0xC0FFEE);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AmFiAdapter adapter;
    LiquidationProxy proxy;
    MockSettlementVault svault;
    DebtToken debt;

    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        // Mocks
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        // Core
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin, true);
        proxy = new LiquidationProxy(pool, sp, admin);
        svault = new MockSettlementVault(address(pool), address(sp), IERC20(address(usdr)), admin);
        debt = pool.DEBT_TOKEN();

        // Wire roles
        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);
        // grant LIQUIDATION_PROXY_ROLE to the proxy on LP
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));
        proxy.setManager(manager, true);

        // Compress timings for tests (allowed in demo mode)
        pool.setLiquidationGracePeriod(60);
        sp.setWithdrawTimelockDuration(60);

        // Mint
        usdr.mint(bob, 10_000_000e18);
        usdr.mint(charlie, 10_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        amfi.mint(charlie, 1_000_000e18);
        vm.stopPrank();
    }

    // ---- Helpers ---------------------------------------------------------

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        pool.approve(address(sp), amount);
        sp.deposit(amount, who);
        vm.stopPrank();
    }

    function _aliceLeveraged(uint256 collateral, uint256 borrowAmount) internal {
        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), collateral);
        pool.depositAsset(address(adapter), abi.encode(collateral));
        pool.borrow(address(adapter), ZERO_DATA, borrowAmount);
        vm.stopPrank();
    }

    function _charlieBorrows(uint256 collateral, uint256 borrowAmount) internal {
        vm.startPrank(charlie);
        pool.openVaultPosition();
        amfi.approve(address(adapter), collateral);
        pool.depositAsset(address(adapter), abi.encode(collateral));
        pool.borrow(address(adapter), ZERO_DATA, borrowAmount);
        vm.stopPrank();
    }

    function _crashOracleBy(uint256 percentBps) internal {
        // 10000 = 100%. e.g. percentBps=3000 → drop 30%
        uint256 cur = oracle.getPrice();
        uint256 newPrice = (cur * (10_000 - percentBps)) / 10_000;
        vm.prank(admin);
        oracle.setPrice(newPrice);
    }

    // ====================================================================
    // 1. Happy path — SP fully covers debt
    // ====================================================================

    function test_happyPath_SP_covered() public {
        // Bob lends 2M, stakes 2M into SP — SP has plenty of capacity.
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);

        // Alice opens 1M collateral, borrows 700k (70% LTV — at the cap)
        _aliceLeveraged(1_000_000e18, 700_000e18);
        uint256 hf0 = pool.calculateHealthFactor(address(adapter), alice, ZERO_DATA);
        // collateral 1M × LT 80% / debt 700k = 1.142...e27
        assertApproxEqRel(hf0, 1.142857e27, 0.01e18);

        // Crash AMFI oracle by 30% → collateral now 700k → HF = 700k×0.8/700k = 0.8 → liquidatable
        _crashOracleBy(3000);
        uint256 hfPost = pool.calculateHealthFactor(address(adapter), alice, ZERO_DATA);
        assertLt(hfPost, 1e27, "HF below 1 after oracle crash");

        // Manager initiates liquidation
        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);

        // Grace period: 60s
        skip(61);

        // Snapshot LP share price before finalize
        uint256 lpSharePriceBefore = pool.convertToAssets(1e18);
        // SP totalAssets before finalize (= raw agToken balance, no batches yet)
        uint256 spTotalBefore = sp.totalAssets();

        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // ---- Assertions on LP-side ----
        // Alice's debt cleared
        assertEq(debt.balanceOf(alice), 0, "Alice debt = 0");
        // Alice's collateral seized (now in MockSettlementVault)
        assertEq(adapter.balanceOf(alice), 0, "Alice collateral = 0");
        assertEq(amfi.balanceOf(address(svault)), 1_000_000e18, "RWA in vault");
        // LP share price flat (within rounding)
        uint256 lpSharePriceAfter = pool.convertToAssets(1e18);
        assertApproxEqRel(lpSharePriceAfter, lpSharePriceBefore, 0.0001e18, "LP share price preserved");

        // ---- Assertions on SP-side ----
        // SP's agTOKEN balance dropped by absorbedShares; pendingPegGap added the same amount
        uint256 spTotalAfter = sp.totalAssets();
        assertApproxEqRel(spTotalAfter, spTotalBefore, 0.0001e18, "SP totalAssets smoothed by pegGap");
        // pegGapPendingForSP = the absorbed assets (≈ 700k USDr)
        assertApproxEqRel(svault.pegGapPendingForSP(), 700_000e18, 0.001e18);

        // Bad-debt accumulator unchanged (SP fully covered)
        assertEq(pool.bdAccLDebt(), 0, "no bad-debt redistribution");
    }

    function test_happyPath_settleWithBonus_SPSharePricePumps() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
        skip(61);
        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // SP share price baseline (post-finalize, pegGap smoothing active)
        uint256 spPriceBeforeSettle = sp.convertToAssets(1e18);

        // Manager settles redemption returning 757k USDr (50k bonus over pegGap of 700k)
        vm.prank(admin);
        usdr.mint(address(svault), 757_000e18);
        vm.prank(admin);
        svault.settleRedemption(1, 757_000e18);

        // pegGap drained, SP totalAssets now reflects raw agTOKEN inflow
        assertEq(svault.pegGapPendingForSP(), 0);
        uint256 spPriceAfterSettle = sp.convertToAssets(1e18);
        // SP share price should have pumped — bonus flowed pro-rata to all stakers
        assertGt(spPriceAfterSettle, spPriceBeforeSettle, "bonus increased SP share price");
    }

    // ====================================================================
    // 2. Bad-debt path — SP cannot cover Alice's full debt
    // ====================================================================

    function test_badDebt_redistributedToCharlie() public {
        // Charlie also borrows so there's an "other active borrower" to absorb redistribution.
        _deposit(bob, 2_000_000e18);
        // Bob stakes only 100k → SP has tiny capacity vs Alice's 700k debt
        _stake(bob, 100_000e18);

        _aliceLeveraged(1_000_000e18, 700_000e18);
        _charlieBorrows(1_000_000e18, 500_000e18); // Charlie also borrows

        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
        skip(61);

        uint256 charlieDebtBefore = debt.balanceOf(charlie);
        uint256 charlieActualBefore = pool.calculateHealthFactor(address(adapter), charlie, ZERO_DATA);

        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // Bad-debt accumulator should have moved
        assertGt(pool.bdAccLDebt(), 0, "bad-debt redistribution triggered");

        // Charlie's "actual" debt (via redistribution) > raw DebtToken balance
        uint256 charlieActualDebt = pool.getPositionScaledDebt(address(adapter), charlie, ZERO_DATA);
        assertGt(charlieActualDebt, charlieDebtBefore, "Charlie picked up extra debt");

        // When Charlie next interacts, the redistribution materializes onto his debt.
        bytes memory zero = ZERO_DATA;
        vm.startPrank(charlie);
        usdr.approve(address(pool), 1);
        pool.repay(address(adapter), zero, 1);
        vm.stopPrank();

        // After materialize, his DebtToken balance reflects the extra debt
        assertGt(debt.balanceOf(charlie), charlieDebtBefore, "Charlie's DebtToken balance grew");
        // Suppress unused-variable warning
        charlieActualBefore;
    }

    // ====================================================================
    // 3. Guard rails
    // ====================================================================

    function test_initiateLiquidation_healthyPosition_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 500_000e18); // 50% LTV — way healthy

        vm.expectRevert(AgamaLendingPool.HealthFactorTooHigh.selector);
        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
    }

    function test_finalizeLiquidation_beforeGrace_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
        // Skip only 30s (grace = 60s)
        skip(30);

        vm.expectRevert(AgamaLendingPool.GracePeriodNotExpired.selector);
        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    function test_alice_canCureDuringGrace() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);

        // Alice repays in full + calls closeLiquidation to cure during grace.
        vm.prank(admin);
        usdr.mint(alice, 200_000e18);
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        pool.repay(address(adapter), ZERO_DATA, type(uint256).max);
        pool.closeLiquidation(address(adapter), ZERO_DATA);
        vm.stopPrank();

        assertEq(debt.balanceOf(alice), 0, "debt cleared");
        AgamaLendingPool.Position memory p = pool.getPosition(address(adapter), alice, ZERO_DATA);
        assertFalse(p.isUnderLiquidation, "liquidation flag cleared");
    }

    function test_borrow_underLiquidation_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);

        vm.prank(alice);
        vm.expectRevert(AgamaLendingPool.CannotActUnderLiquidation.selector);
        pool.borrow(address(adapter), ZERO_DATA, 1);
    }
}

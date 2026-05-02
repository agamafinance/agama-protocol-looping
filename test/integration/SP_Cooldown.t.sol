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

/// @title SP_Cooldown
/// @notice V2 unstake-cooldown semantics on the StabilityPool. Covers:
///   1. request → transfer-away sagYLD → claim returns 0, request consumed
///   2. request, then liquidation queued → unlock extends to settlement close
///   3. multi-requests staggered, each independently claimable
///   4. governance bounds on `setCooldownDuration`
///   5. liquidation depresses pps during cooldown → claim at depressed pps
contract SPCooldownTest is Test {
    address admin = address(0xA11CE);
    address manager = address(0x111A);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);
    address eve = address(0xEEE);

    MockUSDr usdr;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AgamaSettlementVault svault;
    AgamaTreasury treasury;
    AgamaReserveFund rf;
    AgamaFeeCollector feeCollector;
    LiquidationProxy proxy;
    MockTrancheToken rwa;
    MockOracle oracle;
    AmFiAdapter adapter;
    DebtToken debt;

    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Yield", "agYLD", IRM.defaults(), true
        );
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        proxy = new LiquidationProxy(pool, sp, admin);
        debt = pool.DEBT_TOKEN();

        rwa = new MockTrancheToken("Mock Senior", "sMOCK", "Mock", "Senior", 0.12e27, admin);
        oracle = new MockOracle(admin, 1e18);
        adapter = new AmFiAdapter(address(pool), IPricedToken(address(rwa)), oracle, admin, 7500, 8500, 300, 24 hours);

        treasury = new AgamaTreasury(admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr)));
        rf = new AgamaReserveFund(admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr)));
        feeCollector = new AgamaFeeCollector(admin, ITreasuryDeposit(address(treasury)));
        svault = new AgamaSettlementVault(
            admin, address(sp), IAgamaPool(address(pool)), ITreasuryDeposit(address(treasury)), IERC20(address(usdr))
        );

        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
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

        usdr.mint(bob, 5_000_000e18);
        usdr.mint(alice, 1_000_000e18);
        usdr.mint(manager, 10_000_000e18);
        rwa.mint(alice, 1_000_000e18);
        vm.stopPrank();

        // Bob is our SP staker. Lend 1M USDr, stake 500k USDr-equivalent agYLD.
        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e18, bob);
        // 500k USDr × 1e6 offset = 5e29 wei agYLD
        pool.approve(address(sp), 500_000e18 * 1e6);
        sp.deposit(500_000e18 * 1e6, bob);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    function _aliceBorrows(uint256 collat, uint256 borrow) internal {
        vm.startPrank(alice);
        rwa.approve(address(adapter), collat);
        pool.openVaultPosition();
        pool.depositAsset(address(adapter), abi.encode(collat));
        pool.borrow(address(adapter), ZERO_DATA, borrow);
        vm.stopPrank();
    }

    // ────────────────────────────────────────────────────────────────────
    // 1. Transfer sagYLD after requestUnstake → claim returns 0
    // ────────────────────────────────────────────────────────────────────

    function test_transfer_after_request_consumes_request_with_zero_claim() public {
        uint256 sagBal = sp.balanceOf(bob);

        vm.prank(bob);
        uint256 reqId = sp.requestUnstake(100_000e18);

        // Bob transfers ALL his sagYLD to eve.
        vm.prank(bob);
        sp.transfer(eve, sagBal);
        assertEq(sp.balanceOf(bob), 0);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(bob);
        uint256 out = sp.claim(reqId);

        assertEq(out, 0, "claim returns 0 - bob has no sagYLD");
        // Earmark is freed regardless.
        assertEq(sp.earmarkedShares(bob), 0, "earmark cleared");
        // Re-claim same request reverts.
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.AlreadyClaimed.selector);
        sp.claim(reqId);
    }

    // ────────────────────────────────────────────────────────────────────
    // 2. Settlement extension - request right before liquidation
    // ────────────────────────────────────────────────────────────────────
    //   Bob requests at D+0. Alice borrows + gets liquidated at D+1
    //   → settlement window opens, expected close D+1+15. Bob's standard
    //   cooldown D+7 is BEFORE the settlement close → claim must wait
    //   until the settlement window closes.
    //
    //   But: requestUnstake snapshots the SVault state AT REQUEST TIME.
    //   So a request at D+0 (no pending settlement) snapshots ext=0;
    //   a later liquidation does NOT extend it. To exercise the extension,
    //   we need to liquidate FIRST then request.

    function test_request_after_active_liquidation_extends_unlock() public {
        // 1) Setup borrower position.
        _aliceBorrows(100_000e18, 70_000e18);
        // 2) Crash oracle 25% → HF < 1.
        vm.prank(admin);
        oracle.setPrice(0.7e18);
        // 3) Liquidate → seizes RWA into SVault, queues batch.
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
        uint64 nowTs = uint64(block.timestamp);

        // 4) Bob requests unstake - should see settlement extension.
        vm.prank(bob);
        uint256 reqId = sp.requestUnstake(50_000e18);

        AgamaStabilityPool.UnstakeRequest memory r = sp.getRequest(bob, reqId);
        uint64 expectedExt = nowTs + 15 days; // standardSettlementWindow
        assertEq(r.settlementExtensionUntil, expectedExt, "ext snapshotted from SVault");
        uint64 unlock = sp.unlockAt(r);
        assertEq(unlock, expectedExt, "unlock = settlement close (later than reqAt+7d)");

        // Cooldown 7d not enough - claim reverts.
        vm.warp(nowTs + 7 days + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.CooldownNotElapsed.selector);
        sp.claim(reqId);

        // After the settlement window closes, claim works.
        vm.warp(uint256(expectedExt) + 1);
        vm.prank(bob);
        uint256 out = sp.claim(reqId);
        assertGt(out, 0);
    }

    // ────────────────────────────────────────────────────────────────────
    // 3. Multi-requests staggered
    // ────────────────────────────────────────────────────────────────────

    function test_multi_requests_independent_unlocks() public {
        // Fix the time origin so the warp arithmetic is unambiguous.
        vm.warp(1_000_000);

        vm.prank(bob);
        uint256 r0 = sp.requestUnstake(100_000e18);
        // r0.requestedAt = 1_000_000, unlockAt = 1_604_800.

        vm.warp(1_086_400); // +1d
        vm.prank(bob);
        uint256 r1 = sp.requestUnstake(50_000e18);
        // r1.requestedAt = 1_086_400, unlockAt = 1_691_200.

        vm.warp(1_172_800); // +2d
        vm.prank(bob);
        uint256 r2 = sp.requestUnstake(30_000e18);
        // r2.requestedAt = 1_172_800, unlockAt = 1_777_600.

        assertEq(sp.pendingCount(bob), 3);
        assertEq(sp.earmarkedShares(bob), 180_000e18);

        // r0 unlocks at 1_604_800. Warp to 1_604_801.
        vm.warp(1_604_801);
        vm.prank(bob);
        sp.claim(r0);

        // r1 still in cooldown (unlock 1_691_200 > 1_604_801).
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.CooldownNotElapsed.selector);
        sp.claim(r1);

        vm.warp(1_691_201);
        vm.prank(bob);
        sp.claim(r1);

        // r2 still in cooldown (unlock 1_777_600 > 1_691_201).
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.CooldownNotElapsed.selector);
        sp.claim(r2);

        vm.warp(1_777_601);
        vm.prank(bob);
        sp.claim(r2);

        assertEq(sp.earmarkedShares(bob), 0, "all earmarks cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // 4. requestUnstake bounded by free balance (not earmarked)
    // ────────────────────────────────────────────────────────────────────

    function test_request_exceeding_free_balance_reverts() public {
        uint256 sagBal = sp.balanceOf(bob);
        vm.prank(bob);
        sp.requestUnstake(sagBal); // earmark all

        // Cannot request more.
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.InsufficientUnearmarkedShares.selector);
        sp.requestUnstake(1);
    }

    // ────────────────────────────────────────────────────────────────────
    // 5. Governance bounds on cooldownDuration
    // ────────────────────────────────────────────────────────────────────

    function test_setCooldownDuration_bounds() public {
        vm.startPrank(admin);

        vm.expectRevert(AgamaStabilityPool.InvalidCooldown.selector);
        sp.setCooldownDuration(0);

        vm.expectRevert(AgamaStabilityPool.InvalidCooldown.selector);
        sp.setCooldownDuration(31 days);

        sp.setCooldownDuration(1 days);
        assertEq(sp.cooldownDuration(), 1 days);

        sp.setCooldownDuration(30 days);
        assertEq(sp.cooldownDuration(), 30 days);

        vm.stopPrank();
    }

    function test_setCooldownDuration_unauthorized_reverts() public {
        vm.expectRevert();
        sp.setCooldownDuration(7 days);
    }

    // ────────────────────────────────────────────────────────────────────
    // 6. Liquidation during cooldown depresses pps → user tanks losses
    // ────────────────────────────────────────────────────────────────────

    function test_liquidation_during_cooldown_lowers_claim() public {
        // Snapshot pps for 1 whole sagYLD share (1e24 wei, since 24 decimals).
        uint256 ppsBefore = sp.convertToAssets(1e24);

        vm.prank(bob);
        uint256 reqId = sp.requestUnstake(100_000e18);

        // Alice borrows and gets liquidated DURING bob's cooldown.
        _aliceBorrows(100_000e18, 70_000e18);
        vm.prank(admin);
        oracle.setPrice(0.7e18);
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // Settlement extends bob's unlock - he can't escape early.
        AgamaStabilityPool.UnstakeRequest memory r = sp.getRequest(bob, reqId);
        uint64 unlock = sp.unlockAt(r);
        // requestedAt was BEFORE the seizure, so settlementExtension=0 here.
        // unlock = requestedAt + 7d only.
        assertEq(unlock, uint64(r.requestedAt) + 7 days);

        // Mid-flight, the pegGap-shares offset the burnt agYLD exactly, so
        // the SP share price stays flat (this is the smoothing invariant).
        // The realised P&L only shows up at settlement.
        uint256 ppsDuring = sp.convertToAssets(1e24);
        assertEq(ppsDuring, ppsBefore, "pegGap exactly offsets burn pre-settle (smoothing)");

        // Manager settles below par - drives pps down.
        // pegGap = 70k absorbed; settle with only 50k USDr.
        uint256 batchId = svault.nextBatchId();
        vm.startPrank(manager);
        usdr.approve(address(svault), 50_000e18);
        svault.settleRedemption(batchId, 50_000e18);
        vm.stopPrank();

        // Warp past cooldown.
        vm.warp(block.timestamp + 7 days + 1);

        uint256 ppsAfter = sp.convertToAssets(1e24);
        // After settle below par, pegGap clears but cash injection (50k) is
        // less than the 70k that was absorbed -> pps lower than pre-action.
        assertLt(ppsAfter, ppsBefore, "tanker semantics: pps depressed post-settle");

        vm.prank(bob);
        uint256 agYLDOut = sp.claim(reqId);

        // Bob claims at the depressed pps. 100k requested * pps gives the
        // exact convertToAssets at claim time.
        uint256 expectedAtDepressed = (100_000e18 * ppsAfter) / 1e24;
        assertApproxEqAbs(agYLDOut, expectedAtDepressed, 1e18, "claim at depressed pps");
    }
}

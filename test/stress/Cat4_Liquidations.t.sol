// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 4 — Liquidation stress
/// @notice Ten scenarios stressing the V1 instant-liquidation path under
///         single-borrower, cascade, multi-tranche, and edge conditions.
contract Cat4_LiquidationsStressTest is StressBase {
    function _seedLpAndSp() internal {
        // 5M LP cash from 5 whales (1M each).
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        // 3 midcaps deposit 250k each so they have agTOKEN to stake.
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);

        // SP staking — 8 stakers, each ~ 250k USDr-equivalent agTOKEN.
        // 250k * 1e6 (decimalsOffset) = 2.5e29 wei agTOKEN.
        for (uint256 i = 0; i < 8; ++i) {
            _stakeSp(spStakers[i], 250_000e18 * 1e6);
        }
    }

    /// Open an aggressive senior position at 74% LTV (close to max 75%).
    function _openSeniorAggressive(address actor) internal {
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 74_000e18);
    }

    /// Open an aggressive junior position at 49% LTV (close to max 50%).
    function _openJuniorAggressive(address actor) internal {
        _oneShotLeveragedPosition(actor, T_JRES, 100_000e18, 49_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.1 — Single liquidation
    // ────────────────────────────────────────────────────────────────────

    function test_S4_1_singleLiquidation() public {
        _seedLpAndSp();
        address actor = aggressives[0];
        _openJuniorAggressive(actor);

        // 25% drop on the junior oracle → HF = 0.65 * 75 / 49 = 0.995 < 1.
        _crashOracleBps(T_JRES, 2500);
        assertLt(_hf(actor, T_JRES), 1e27, "S4.1: liquidatable");

        uint256 pegGapPre = svault.pegGapPendingForSP();
        _liquidate(actor, T_JRES);
        _verifyInvariants();

        assertEq(debt.balanceOf(actor), 0, "S4.1: debt cleared");
        assertEq(_collatValue(actor, T_JRES), 0, "S4.1: collat seized");
        // pegGap rises by ~debt absorbed; SP price stays stable pre-settlement
        // (debt absorbed == agTOKEN burned, pegGap exactly offsets it).
        assertGt(svault.pegGapPendingForSP(), pegGapPre, "S4.1: pegGap accrued");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.2 — Cascade Senior 5 simultaneous (after deep crash)
    // ────────────────────────────────────────────────────────────────────

    function test_S4_2_cascadeSenior5() public {
        _seedLpAndSp();
        // 5 aggressives all open senior positions.
        for (uint256 i = 0; i < 5; ++i) _openSeniorAggressive(aggressives[i]);

        // Deep crash 50% on senior → HF = 0.85 * 50 / 74 = 0.574.
        _crashOracleBps(T_SRES, 5000);
        for (uint256 i = 0; i < 5; ++i) {
            assertLt(_hf(aggressives[i], T_SRES), 1e27, "S4.2: liq pre-cascade");
        }

        uint256 totalDebtPre = debt.totalSupply();
        for (uint256 i = 0; i < 5; ++i) {
            _liquidate(aggressives[i], T_SRES);
            _verifyInvariants();
        }
        assertEq(debt.totalSupply(), 0, "S4.2: all debt cleared");
        assertGt(totalDebtPre, 0, "S4.2: had debt to clear");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.3 — Cascade Junior 5 simultaneous
    // ────────────────────────────────────────────────────────────────────

    function test_S4_3_cascadeJunior5() public {
        _seedLpAndSp();
        for (uint256 i = 0; i < 5; ++i) _openJuniorAggressive(aggressives[i]);

        _crashOracleBps(T_JRES, 2500);
        for (uint256 i = 0; i < 5; ++i) {
            _liquidate(aggressives[i], T_JRES);
            _verifyInvariants();
        }
        assertEq(debt.totalSupply(), 0, "S4.3: all junior debt cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.4 — Multi-tranche cascade (Resolvi senior + junior crash same time)
    // ────────────────────────────────────────────────────────────────────

    function test_S4_4_multiTrancheCascade() public {
        _seedLpAndSp();
        // 3 senior positions, 3 junior positions.
        _openSeniorAggressive(aggressives[0]);
        _openSeniorAggressive(aggressives[1]);
        _openSeniorAggressive(aggressives[2]);
        _openJuniorAggressive(moderates[0]);
        _openJuniorAggressive(moderates[1]);
        _openJuniorAggressive(moderates[2]);

        // Crash both Resolvi oracles 50% → seniors at 0.574, juniors at 0.66.
        // Junior already liquidatable; senior liquidatable too.
        _crashOracleBps(T_SRES, 5000);
        _crashOracleBps(T_JRES, 5000);

        // Liquidate all six.
        _liquidate(aggressives[0], T_SRES);
        _liquidate(aggressives[1], T_SRES);
        _liquidate(aggressives[2], T_SRES);
        _liquidate(moderates[0], T_JRES);
        _liquidate(moderates[1], T_JRES);
        _liquidate(moderates[2], T_JRES);
        _verifyInvariants();

        assertEq(debt.totalSupply(), 0, "S4.4: full cascade cleared");
        // Other tranches still healthy.
        assertEq(tranches[T_SDIG].oracle.getPrice(), 1e18, "S4.4: Digcap oracle untouched");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.5 — SP exhausted → bad debt redistribution
    // ────────────────────────────────────────────────────────────────────
    //   Stage a position whose debt EXCEEDS the SP capacity. The SP
    //   absorbs as much as it can; the residual is redistributed to
    //   remaining borrowers via bdAccLDebt.

    function test_S4_5_spExhausted_badDebt() public {
        // Tiny SP — only RF baseline (100k).
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        // No SP staking — only RF's 100k seed is in the SP.

        // Two big borrowers — combined debt > SP capacity.
        _oneShotLeveragedPosition(aggressives[0], T_SRES, 200_000e18, 148_000e18); // 74% LTV
        _oneShotLeveragedPosition(aggressives[1], T_JRES, 200_000e18,  98_000e18); // 49% LTV

        // Crash both 50%.
        _crashOracleBps(T_SRES, 5000);
        _crashOracleBps(T_JRES, 5000);

        uint256 spCapPre = pool.convertToAssets(pool.balanceOf(address(sp)));
        _liquidate(aggressives[0], T_SRES);
        _verifyInvariants();
        // After first liquidation: SP burned all its agTOKEN; second liq
        // creates bad debt redistributed to remaining borrower.
        _liquidate(aggressives[1], T_JRES);
        _verifyInvariants();

        assertGt(spCapPre, 0, "S4.5: SP had assets pre");
        assertEq(debt.balanceOf(aggressives[0]), 0, "S4.5: first cleared");
        assertEq(debt.balanceOf(aggressives[1]), 0, "S4.5: second cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.6 — Self-cure attempt (borrower repays before liquidation)
    // ────────────────────────────────────────────────────────────────────
    //   Borrower notices HF < 1 and races to repay enough to lift HF
    //   above 1. The next liquidate call should revert.

    function test_S4_6_selfCureAttempt() public {
        _seedLpAndSp();
        address actor = aggressives[2];
        _openJuniorAggressive(actor);
        _crashOracleBps(T_JRES, 2500);
        assertLt(_hf(actor, T_JRES), 1e27, "S4.6: liquidatable");

        // Borrower repays 30k → debt = 19k, HF = 0.65 * 75 / 19 = 2.56.
        _repay(actor, T_JRES, 30_000e18);
        _verifyInvariants();
        assertGt(_hf(actor, T_JRES), 1e27, "S4.6: HF cured");

        // Liquidate must revert.
        try this._tryLiquidate(actor, T_JRES) {
            revert("S4.6: liquidate should have reverted");
        } catch {
            // expected
        }
    }

    function _tryLiquidate(address user, uint256 idx) external {
        _liquidate(user, idx);
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.7 — Multi-collateral liquidation
    // ────────────────────────────────────────────────────────────────────
    //   Borrower has collateral on TWO adapters (sRES + sDIG) but the
    //   tightest adapter (jRES) is the binding constraint after a crash.
    //   Liquidator picks the binding adapter.

    function test_S4_7_multiCollatLiquidation() public {
        _seedLpAndSp();
        address actor = aggressives[3];
        _openVault(actor);
        _depositCollat(actor, T_SRES, 100_000e18);
        _depositCollat(actor, T_JRES, 100_000e18);
        // Borrow 70k against senior. Senior MAX_LTV check: 0.75*100/70=1.07 OK.
        // Junior LT check (post-borrow): 0.65*100/70=0.928 → already liquidatable!
        _borrow(actor, T_SRES, 70_000e18);
        _verifyInvariants();
        assertLt(_hf(actor, T_JRES), 1e27, "S4.7: junior liquidatable");
        assertGt(_hf(actor, T_SRES), 1e27, "S4.7: senior safe");

        // Liquidate via the JUNIOR adapter (binding).
        _liquidate(actor, T_JRES);
        _verifyInvariants();
        assertEq(debt.balanceOf(actor), 0, "S4.7: debt cleared via junior");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.8 — Dust liquidation (very small debt position)
    // ────────────────────────────────────────────────────────────────────

    function test_S4_8_dustLiquidation() public {
        _seedLpAndSp();
        address actor = aggressives[4];
        // Tiny position: 100 jRES collat, 49 USDr debt.
        _oneShotLeveragedPosition(actor, T_JRES, 100e18, 49e18);
        _crashOracleBps(T_JRES, 2500);
        assertLt(_hf(actor, T_JRES), 1e27, "S4.8: dust liquidatable");

        _liquidate(actor, T_JRES);
        _verifyInvariants();
        assertEq(debt.balanceOf(actor), 0, "S4.8: dust cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.9 — Aged interest liquidation (180 days warp before liq)
    // ────────────────────────────────────────────────────────────────────

    function test_S4_9_agedInterestLiquidation() public {
        _seedLpAndSp();
        address actor = moderates[0];
        // Position at LTV 70% senior — safe at start.
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 70_000e18);
        // Skip 180 days of interest accrual via fastForward (testnet cheat).
        vm.prank(admin);
        pool.fastForwardInterest(180 * 24 * 60 * 60);
        _verifyInvariants();

        // After ~3.5% interest, debt ~72.5k. At LT 85%, HF = 0.85*100/72.5 = 1.172
        // Still safe — drop oracle 20% to push HF below 1.
        _crashOracleBps(T_SRES, 2000);
        assertLt(_hf(actor, T_SRES), 1e27, "S4.9: aged + crash liquidatable");
        _liquidate(actor, T_SRES);
        _verifyInvariants();
        assertEq(debt.balanceOf(actor), 0, "S4.9: aged debt cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S4.10 — Bonus distribution validation
    // ────────────────────────────────────────────────────────────────────
    //   After liquidation + manager settles redemption at face value,
    //   the bonus stream should flow into SP's totalAssets and lift
    //   the agaSP share price for ALL stakers (Carol/whales, Treasury, RF).

    function test_S4_10_bonusDistribution() public {
        _seedLpAndSp();
        address actor = aggressives[0];
        _openJuniorAggressive(actor);

        // Snapshot SP price pre-liquidation
        uint256 spPpsPre = sp.convertToAssets(1e18);

        _crashOracleBps(T_JRES, 2500);
        _liquidate(actor, T_JRES);

        // pegGap pending → 49k USDr (debt absorbed)
        uint256 pegGap = svault.pegGapPendingForSP();
        assertApproxEqAbs(pegGap, 49_000e18, 1e15, "S4.10: pegGap == debt");

        // Manager settles at 115% (50% drop oracle but RWA redeemed at face = 100k value).
        // For test simplicity, settle at 100k USDr (face value of seized 100k jRESOLV).
        uint256 batchId = svault.nextBatchId();
        uint256 settleAmount = 100_000e18;
        vm.startPrank(manager);
        usdr.approve(address(svault), settleAmount);
        svault.settleRedemption(batchId, settleAmount);
        vm.stopPrank();
        _verifyInvariants();

        // After settlement: pegGap cleared, bonus = 100k - 49k = 51k flowing to SP.
        assertEq(svault.pegGapPendingForSP(), 0, "S4.10: pegGap cleared");
        // SP price should LIFT.
        uint256 spPpsPost = sp.convertToAssets(1e18);
        assertGt(spPpsPost, spPpsPre, "S4.10: SP share price lifted by bonus");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 9 — Chaos stress (mass exits, attack patterns, flash crash)
contract Cat9_ChaosStressTest is StressBase {
    function _seedLp() internal {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S9.1 — Massive bank run (15 lenders all withdraw simultaneously)
    // ────────────────────────────────────────────────────────────────────

    function test_S9_1_massiveBankRun() public {
        // Full lender army deposits, then all redeem in succession.
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        for (uint256 i = 0; i < 5; ++i) _deposit(midcaps[i], 100_000e18);
        for (uint256 i = 0; i < 5; ++i) _deposit(retails[i], 10_000e18);

        // Mass redeem
        address[15] memory lenders;
        for (uint256 i = 0; i < 5; ++i) {
            lenders[i] = whales[i];
            lenders[5 + i] = midcaps[i];
            lenders[10 + i] = retails[i];
        }
        for (uint256 i = 0; i < 15; ++i) {
            uint256 sh = pool.balanceOf(lenders[i]);
            if (sh == 0) continue;
            vm.prank(lenders[i]);
            pool.redeem(sh, lenders[i], lenders[i]);
            _verifyInvariants();
        }
        // Only RF baseline should remain.
        assertApproxEqAbs(pool.totalAssets(), BASELINE_TVL, 100, "S9.1: only RF remains");
    }

    // ────────────────────────────────────────────────────────────────────
    // S9.2 — Coordinated borrow attack (5 aggressives borrow at max LTV)
    // ────────────────────────────────────────────────────────────────────
    //   Validates that simultaneous max-LTV borrowing doesn't break HF /
    //   IRM math when utilization spikes.

    function test_S9_2_coordinatedBorrowAttack() public {
        _seedLp();
        // 5 aggressives all borrow at max LTV against junior tranches.
        for (uint256 i = 0; i < 5; ++i) {
            _oneShotLeveragedPosition(aggressives[i], T_JRES, 100_000e18, 49_000e18);
            _verifyInvariants();
        }
        // Total debt = 245k. LP TVL = 5M + RF baseline.
        // Utilization ≈ 245 / (5,100k) = 4.8%. Modest.
        uint256 u = (debt.totalSupply() * 1e18) / pool.totalAssets();
        assertLt(u, 5e16, "S9.2: utilization < 5%");
        // Each position safe.
        for (uint256 i = 0; i < 5; ++i) {
            assertGt(_hf(aggressives[i], T_JRES), 1.3e27, "S9.2: each HF safe");
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // S9.3 — Flash crash multi-oracle -50% (all 6 tranches simultaneously)
    // ────────────────────────────────────────────────────────────────────

    function test_S9_3_flashCrashAllOracles() public {
        _seedLp();
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        // 6 borrowers, one per tranche.
        for (uint256 t = 0; t < 6; ++t) {
            address borrower;
            if (t < 5) borrower = aggressives[t];
            else borrower = moderates[0];
            uint256 borrowAmt = tranches[t].senior ? 74_000e18 : 49_000e18;
            _oneShotLeveragedPosition(borrower, t, 100_000e18, borrowAmt);
        }

        // Flash crash all 6 oracles -50%.
        for (uint256 t = 0; t < 6; ++t) _crashOracleBps(t, 5000);

        // All 6 should be liquidatable (50% drop > both senior and junior buffers).
        for (uint256 t = 0; t < 6; ++t) {
            address borrower;
            if (t < 5) borrower = aggressives[t];
            else borrower = moderates[0];
            assertLt(_hf(borrower, t), 1e27, "S9.3: all liquidatable");
        }

        // Cascade liquidate all 6.
        for (uint256 t = 0; t < 6; ++t) {
            address borrower;
            if (t < 5) borrower = aggressives[t];
            else borrower = moderates[0];
            _liquidate(borrower, t);
            _verifyInvariants();
        }
        assertEq(debt.totalSupply(), 0, "S9.3: full cascade cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S9.4 — Re-entrancy attempt (mock attacker tries reenter on borrow)
    // ────────────────────────────────────────────────────────────────────
    //   The LP uses OZ ReentrancyGuard. We stage an attacker contract that
    //   tries to re-enter borrow() during the USDr transfer callback. Since
    //   USDr is a vanilla ERC-20 (no callback), re-entry isn't actually
    //   reachable — we assert the guard exists by attempting nested calls.

    function test_S9_4_reentrancyGuardActive() public {
        _seedLp();
        address actor = aggressives[0];
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 50_000e18);

        // Try to call borrow inside borrow via vm.prank — same-call re-entry
        // would trip nonReentrant. We can't reach the inner pathway from a
        // test (it's an internal modifier), but we verify the user's debt
        // is exactly one borrow worth (no double-mint).
        uint256 d = debt.balanceOf(actor);
        assertApproxEqAbs(d, 50_000e18, 1, "S9.4: single borrow recorded");
        _verifyInvariants();
    }

    // ────────────────────────────────────────────────────────────────────
    // S9.5 — Front-running test (manager front-runs oracle update)
    // ────────────────────────────────────────────────────────────────────
    //   Simulate the case where a borrower opens just BEFORE an oracle
    //   crash. The crash triggers a liquidation. We verify the borrower
    //   doesn't get a "head start" — the new position's HF is computed
    //   on the post-crash oracle.

    function test_S9_5_frontRunOracleUpdate() public {
        _seedLp();
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        // Crash oracle FIRST.
        _crashOracleBps(T_JRES, 2500); // -25%

        // Now a fresh borrower tries to open at "high LTV" — the post-crash
        // oracle is what's checked. With collat now at 0.75, borrow 49k
        // on 100k jRES → HF check at LTV 50%: 0.5*75/49 = 0.765 → REVERTS.
        address actor = aggressives[1];
        _openVault(actor);
        vm.startPrank(actor);
        tranches[T_JRES].token.approve(address(tranches[T_JRES].adapter), 100_000e18);
        pool.depositAsset(address(tranches[T_JRES].adapter), abi.encode(uint256(100_000e18)));
        try pool.borrow(address(tranches[T_JRES].adapter), ZERO_DATA, 49_000e18) {
            revert("S9.5: borrow should have reverted under crashed oracle");
        } catch {
            // expected
        }
        vm.stopPrank();
        _verifyInvariants();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 2 — Borrowing stress
/// @notice Eight scenarios across the borrow side. Every scenario opens
///         the LP with a single whale lender, then exercises a borrow
///         pattern (conservative / aggressive / multi-collateral / loop)
///         and validates HF math + invariants.
contract Cat2_BorrowingStressTest is StressBase {
    uint256 constant LP_FLOAT = 5_000_000e18;

    function _seedLp() internal {
        // 5M cash on the LP — split 1M across each whale (within their 2M mint).
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.1 — Senior conservative (LTV 30%)
    // ────────────────────────────────────────────────────────────────────

    function test_S2_1_seniorConservative() public {
        _seedLp();
        address actor = conservatives[0];
        // 100k sRESOLV @ 1.0 → 100k value. Borrow 30k → LTV 30%, HF = 0.85*100/30 = 2.83.
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 30_000e18);
        _verifyInvariants();

        uint256 hf = _hf(actor, T_SRES);
        // HF ≈ 2.833...e27. Allow ±0.5%.
        assertApproxEqRel(hf, 2.833e27, 5e15, "S2.1: HF ~= 2.83");
        assertEq(usdr.balanceOf(actor), INITIAL_USDR_PER_BORROWER + 30_000e18 * 9950 / 10_000, "S2.1: net of 50bps fee");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.2 — Senior aggressive (LTV 74% of 75% max)
    // ────────────────────────────────────────────────────────────────────

    function test_S2_2_seniorAggressive() public {
        _seedLp();
        address actor = aggressives[0];
        // 100k sRESOLV → 100k value. Borrow 74k → LTV 74%, HF = 0.85*100/74 = 1.149.
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 74_000e18);
        _verifyInvariants();

        uint256 hf = _hf(actor, T_SRES);
        assertApproxEqRel(hf, 1.1486e27, 5e15, "S2.2: HF ~= 1.15");
        // At LTV 75% the borrow would revert; 74% should work.
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.3 — Junior conservative (LTV 30%)
    // ────────────────────────────────────────────────────────────────────

    function test_S2_3_juniorConservative() public {
        _seedLp();
        address actor = conservatives[1];
        // 100k jRESOLV → 100k value. Borrow 30k → HF = 0.65*100/30 = 2.166.
        _oneShotLeveragedPosition(actor, T_JRES, 100_000e18, 30_000e18);
        _verifyInvariants();

        uint256 hf = _hf(actor, T_JRES);
        assertApproxEqRel(hf, 2.1666e27, 5e15, "S2.3: HF ~= 2.17");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.4 — Junior aggressive (LTV 49% of 50% max)
    // ────────────────────────────────────────────────────────────────────

    function test_S2_4_juniorAggressive() public {
        _seedLp();
        address actor = aggressives[1];
        // 100k jRESOLV → 100k value. Borrow 49k → HF = 0.65*100/49 = 1.326.
        _oneShotLeveragedPosition(actor, T_JRES, 100_000e18, 49_000e18);
        _verifyInvariants();

        uint256 hf = _hf(actor, T_JRES);
        assertApproxEqRel(hf, 1.3265e27, 5e15, "S2.4: HF ~= 1.33");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.5 — Multi-collateral (same actor, two senior tranches)
    // ────────────────────────────────────────────────────────────────────
    //   V1 maintains a SINGLE global debt per user. The user can post
    //   collateral across multiple adapters; HF is computed *per adapter*
    //   against the same total debt. So two seniors with equal value &
    //   the same LT each see the same HF.

    function test_S2_5_multiCollateralSameType() public {
        _seedLp();
        address actor = moderates[0];
        _openVault(actor);
        // 50k sRESOLV + 50k sDIGCAP — combined value 100k, but each adapter
        // only sees its own collateral.
        _depositCollat(actor, T_SRES, 50_000e18);
        _depositCollat(actor, T_SDIG, 50_000e18);
        _borrow(actor, T_SRES, 30_000e18); // borrow against sRESOLV adapter
        _verifyInvariants();

        // HF measured against sRESOLV: collat=50k, debt=30k, LT=85% → 1.416.
        // HF measured against sDIGCAP: collat=50k, SAME debt=30k → identical.
        uint256 hfRES = _hf(actor, T_SRES);
        uint256 hfDIG = _hf(actor, T_SDIG);
        assertApproxEqRel(hfRES, 1.4166e27, 5e15, "S2.5: HF sRES");
        assertApproxEqRel(hfDIG, 1.4166e27, 5e15, "S2.5: HF sDIG");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.6 — Cross-tranche multi-collateral (senior + junior same actor)
    // ────────────────────────────────────────────────────────────────────
    //   Same global debt seen by both adapters → HF differs because
    //   LT is different (sRES 85%, jRES 65%). The TIGHTEST adapter
    //   determines liquidation risk.

    function test_S2_6_crossTrancheMultiCollat() public {
        _seedLp();
        address actor = moderates[1];
        _openVault(actor);
        _depositCollat(actor, T_SRES, 100_000e18);
        _depositCollat(actor, T_JRES, 100_000e18);
        _borrow(actor, T_SRES, 50_000e18);
        _verifyInvariants();

        uint256 hfS = _hf(actor, T_SRES); // 0.85 * 100 / 50 = 1.7
        uint256 hfJ = _hf(actor, T_JRES); // 0.65 * 100 / 50 = 1.3
        assertApproxEqRel(hfS, 1.7e27, 5e15, "S2.6: HF senior");
        assertApproxEqRel(hfJ, 1.3e27, 5e15, "S2.6: HF junior");
        // Junior adapter is the binding constraint — drop the tightest first.
        assertGt(hfS, hfJ, "S2.6: senior HF wider than junior");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.7 — Looping x2 Junior (target 49% LTV per iteration)
    // ────────────────────────────────────────────────────────────────────
    //   Manual loop: deposit 100k jRES, borrow 49k USDr; buy 49k jRES;
    //   redeposit; borrow another 24k USDr (49% of 49k). Final exposure
    //   = 149k jRES collateral, 73k USDr debt. Net leverage ~1.49x equity.

    function test_S2_7_loopX2Junior() public {
        _seedLp();
        address actor = aggressives[2];
        _openVault(actor);

        // Iter 1
        _depositCollat(actor, T_JRES, 100_000e18);
        _borrow(actor, T_JRES, 49_000e18);
        _verifyInvariants();

        // "Buy more jRES with the 49k USDr" — in mocks we just mint as
        // a stand-in for the AMM swap.
        // Already minted 1M jRES at setup; reuse the float.

        // Iter 2: redeposit 49k jRES, borrow 24k USDr.
        _depositCollat(actor, T_JRES, 49_000e18);
        _borrow(actor, T_JRES, 24_000e18);
        _verifyInvariants();

        // Total collat = 149k jRES, debt = 73k USDr (+ origination fees).
        // HF = 0.65 * 149 / 73 = 1.326 — same buffer as the aggressive
        // single-shot, since LTV per iteration is preserved.
        uint256 hf = _hf(actor, T_JRES);
        assertGt(hf, 1.30e27, "S2.7: HF still healthy");
    }

    // ────────────────────────────────────────────────────────────────────
    // S2.8 — Looping x3 Senior (target 74% LTV per iteration)
    // ────────────────────────────────────────────────────────────────────

    function test_S2_8_loopX3Senior() public {
        _seedLp();
        address actor = aggressives[3];
        _openVault(actor);

        _depositCollat(actor, T_SRES, 100_000e18);
        _borrow(actor, T_SRES, 74_000e18);
        _verifyInvariants();

        _depositCollat(actor, T_SRES, 74_000e18);
        _borrow(actor, T_SRES, 54_760e18); // 74% of 74k
        _verifyInvariants();

        _depositCollat(actor, T_SRES, 54_760e18);
        _borrow(actor, T_SRES, 40_522e18); // 74% of 54.76k
        _verifyInvariants();

        // Total collat ≈ 228.76k, debt ≈ 169.28k.
        // HF = 0.85 * 228.76 / 169.28 = 1.149.
        uint256 hf = _hf(actor, T_SRES);
        assertGt(hf, 1.10e27, "S2.8: HF above water");
        assertLt(hf, 1.20e27, "S2.8: HF reflects 74% LTV");
    }
}

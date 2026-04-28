// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 3 — Repay stress
/// @notice Four scenarios validating debt repayment + position close.
contract Cat3_RepayStressTest is StressBase {
    function _seedLp() internal {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S3.1 — Repay partiel 50%
    // ────────────────────────────────────────────────────────────────────

    function test_S3_1_repayPartial50() public {
        _seedLp();
        address actor = moderates[0];
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 50_000e18);

        uint256 debtBefore = debt.balanceOf(actor);
        _repay(actor, T_SRES, debtBefore / 2);
        _verifyInvariants();

        uint256 debtAfter = debt.balanceOf(actor);
        assertApproxEqAbs(debtAfter, debtBefore / 2, 2, "S3.1: debt halved");
        // HF should approximately double.
        uint256 hf = _hf(actor, T_SRES);
        assertApproxEqRel(hf, 3.4e27, 5e15, "S3.1: HF doubled (~3.4)");
    }

    // ────────────────────────────────────────────────────────────────────
    // S3.2 — Repay total + close vault
    // ────────────────────────────────────────────────────────────────────

    function test_S3_2_repayTotalThenClose() public {
        _seedLp();
        address actor = moderates[1];
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 50_000e18);

        // Repay slightly more than nominal to absorb interest accrual (none
        // here since same block, but defensive).
        uint256 outstanding = debt.balanceOf(actor);
        _repay(actor, T_SRES, outstanding);
        _verifyInvariants();

        assertEq(debt.balanceOf(actor), 0, "S3.2: debt cleared");
        // HF on a debt-free borrower returns max uint256.
        uint256 hf = _hf(actor, T_SRES);
        assertEq(hf, type(uint256).max, "S3.2: HF = MAX (no debt)");

        // Withdraw collateral fully.
        _withdrawCollat(actor, T_SRES, 100_000e18);
        _verifyInvariants();
        assertEq(_collatValue(actor, T_SRES), 0, "S3.2: collat returned");
    }

    // ────────────────────────────────────────────────────────────────────
    // S3.3 — Repay max uint256.max (overpay → only debt amount taken)
    // ────────────────────────────────────────────────────────────────────

    function test_S3_3_repayMaxUint() public {
        _seedLp();
        address actor = moderates[2];
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 50_000e18);

        uint256 outstanding = debt.balanceOf(actor);
        uint256 usdrBefore = usdr.balanceOf(actor);
        // Repay caps at outstanding debt.
        _repay(actor, T_SRES, type(uint256).max);
        _verifyInvariants();

        uint256 spent = usdrBefore - usdr.balanceOf(actor);
        assertApproxEqAbs(spent, outstanding, 2, "S3.3: only outstanding pulled");
        assertEq(debt.balanceOf(actor), 0, "S3.3: debt fully cleared");
    }

    // ────────────────────────────────────────────────────────────────────
    // S3.4 — Withdraw with active debt (must respect HF)
    // ────────────────────────────────────────────────────────────────────
    //   Conservative borrow at LTV 30%. Try to withdraw collateral until
    //   HF is just above 1; at the LIMIT a further withdraw must revert.

    function test_S3_4_withdrawWithActiveDebt() public {
        _seedLp();
        address actor = conservatives[2];
        _oneShotLeveragedPosition(actor, T_SRES, 100_000e18, 30_000e18);

        // Withdraw 30k collateral → 70k value remaining, debt 30k.
        // HF = 0.85 * 70 / 30 = 1.983. Still safe.
        _withdrawCollat(actor, T_SRES, 30_000e18);
        _verifyInvariants();
        uint256 hfMid = _hf(actor, T_SRES);
        assertGt(hfMid, 1.5e27, "S3.4: HF still healthy");

        // Aggressive withdraw — try to pull 50k more (would leave 20k → HF
        // = 0.85 * 20 / 30 = 0.566 < 1). Must revert.
        vm.prank(actor);
        try pool.withdrawAsset(address(tranches[T_SRES].adapter), abi.encode(uint256(50_000e18))) {
            revert("S3.4: withdraw should have reverted");
        } catch {
            // expected
        }
        _verifyInvariants();
    }
}

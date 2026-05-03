// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 8 — Long-running stress (vm.warp time-travel)
contract Cat8_LongRunningStressTest is StressBase {
    function _seedLpSpAndOpen() internal {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);
        _oneShotLeveragedPosition(moderates[0], T_SRES, 100_000e18, 50_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S8.1 — Yield accrual 24h+ (debt grows; LP appreciates)
    // ────────────────────────────────────────────────────────────────────

    function test_S8_1_yieldAccrual24h() public {
        _seedLpSpAndOpen();
        uint256 debtPre = debt.balanceOf(moderates[0]);
        uint256 lpPpsPre = pool.convertToAssets(1e18 * 1e6);

        // 24h via fastForwardInterest cheat.
        vm.prank(admin);
        pool.fastForwardInterest(24 hours);
        _verifyInvariants();

        uint256 debtPost = debt.balanceOf(moderates[0]);
        uint256 lpPpsPost = pool.convertToAssets(1e18 * 1e6);

        assertGt(debtPost, debtPre, "S8.1: debt accrued");
        assertGt(lpPpsPost, lpPpsPre, "S8.1: LP appreciated");
    }

    // ────────────────────────────────────────────────────────────────────
    // S8.2 — Treasury bonus accumulation across 3 fees
    // ────────────────────────────────────────────────────────────────────

    function test_S8_2_treasuryBonusAccumulation() public {
        // Re-enable origination fee for this fee-mechanism test
        vm.prank(admin);
        pool.setOriginationFee(50);

        _seedLpSpAndOpen(); // 1 origination fee already collected
        uint256 t1 = sp.balanceOf(address(treasury));

        _oneShotLeveragedPosition(moderates[1], T_SDIG, 200_000e18, 100_000e18);
        uint256 t2 = sp.balanceOf(address(treasury));

        _oneShotLeveragedPosition(moderates[2], T_JCON, 200_000e18, 90_000e18);
        uint256 t3 = sp.balanceOf(address(treasury));

        assertGt(t2, t1, "S8.2: 2nd fee accumulated");
        assertGt(t3, t2, "S8.2: 3rd fee accumulated");
        _verifyInvariants();
    }

    // ────────────────────────────────────────────────────────────────────
    // S8.3 — Multi-day stress (3 days of accrual + cascade liquidation)
    // ────────────────────────────────────────────────────────────────────

    function test_S8_3_multiDayStress() public {
        _seedLpSpAndOpen();

        // Add 4 more aggressive borrowers across the 3 pools.
        _oneShotLeveragedPosition(aggressives[0], T_SRES, 200_000e18, 148_000e18); // 74%
        _oneShotLeveragedPosition(aggressives[1], T_JRES, 200_000e18,  98_000e18); // 49%
        _oneShotLeveragedPosition(aggressives[2], T_SDIG, 200_000e18, 148_000e18);
        _oneShotLeveragedPosition(aggressives[3], T_JDIG, 200_000e18,  98_000e18);

        // 3 days of interest accrual.
        vm.prank(admin);
        pool.fastForwardInterest(3 days);
        _verifyInvariants();

        // Crash all four oracles 50%.
        _crashOracleBps(T_SRES, 5000);
        _crashOracleBps(T_JRES, 5000);
        _crashOracleBps(T_SDIG, 5000);
        _crashOracleBps(T_JDIG, 5000);

        // Cascade liquidate.
        _liquidate(aggressives[0], T_SRES);
        _liquidate(aggressives[1], T_JRES);
        _liquidate(aggressives[2], T_SDIG);
        _liquidate(aggressives[3], T_JDIG);
        _verifyInvariants();

        // moderates[0] still has its modest senior position (50% LTV at 50% drop):
        // HF = 0.85*50/50_with_interest. May or may not be liquidatable.
        // Assert: most debt cleared.
        uint256 totalRemainingDebt = debt.totalSupply();
        assertLt(totalRemainingDebt, 100_000e18, "S8.3: most debt cleared");
    }
}

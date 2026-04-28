// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 5 — Stability Pool stress
/// @notice Six scenarios validating SP stake / unstake / appreciation /
///         protocol-side auto-stake (Treasury + RF).
contract Cat5_StabilityPoolStressTest is StressBase {
    function _seedLp() internal {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.1 — Direct stake (whale lends, then stakes)
    // ────────────────────────────────────────────────────────────────────

    function test_S5_1_directStake() public {
        _seedLp();
        address actor = whales[0];
        // Whale has 1M agTOKEN-equivalent. Stake 500k USDr-eq → 5e29 wei agTOKEN.
        _stakeSp(actor, 500_000e18 * 1e6);
        _verifyInvariants();

        uint256 agaSp = sp.balanceOf(actor);
        assertGt(agaSp, 0, "S5.1: agaSP minted");
        // ERC4626: agaSP-equivalent in agTOKEN should equal what we deposited.
        assertApproxEqAbs(sp.convertToAssets(agaSp), 500_000e18 * 1e6, 1e6, "S5.1: round trip");
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.2 — Stake AFTER multiple lend rounds
    // ────────────────────────────────────────────────────────────────────

    function test_S5_2_stakeAfterMultipleLends() public {
        _seedLp();
        address actor = midcaps[0];
        // Midcap deposits twice (50k + 50k = 100k).
        _deposit(actor, 50_000e18);
        _deposit(actor, 50_000e18);
        // Stake the full agTOKEN balance.
        uint256 fullAg = pool.balanceOf(actor);
        _stakeSp(actor, fullAg);
        _verifyInvariants();

        assertEq(pool.balanceOf(actor), 0, "S5.2: agTOKEN drained");
        assertGt(sp.balanceOf(actor), 0, "S5.2: agaSP issued");
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.3 — Unstake (redeem agaSP for agTOKEN)
    // ────────────────────────────────────────────────────────────────────

    function test_S5_3_unstakeRedeem() public {
        _seedLp();
        address actor = whales[1];
        _stakeSp(actor, 200_000e18 * 1e6);
        uint256 agaSp = sp.balanceOf(actor);

        // SP has a same-block guard against deposit-then-withdraw. Advance
        // by 1 block before redeeming to clear it.
        vm.roll(block.number + 1);

        // Redeem half.
        vm.prank(actor);
        sp.redeem(agaSp / 2, actor, actor);
        _verifyInvariants();

        assertApproxEqAbs(sp.balanceOf(actor), agaSp / 2, 1, "S5.3: half redeemed");
        // agTOKEN balance should rise by ~100k USDr-eq.
        uint256 agTokenBack = pool.balanceOf(actor);
        assertGt(agTokenBack, 0, "S5.3: agTOKEN returned");
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.4 — SP appreciation post-liquidation + settlement
    // ────────────────────────────────────────────────────────────────────

    function test_S5_4_spAppreciationAfterLiquidation() public {
        _seedLp();
        // 8 stakers (mirrors Cat4 setup).
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        // Borrower opens, gets liquidated.
        _oneShotLeveragedPosition(aggressives[0], T_JRES, 100_000e18, 49_000e18);
        _crashOracleBps(T_JRES, 2500);
        _liquidate(aggressives[0], T_JRES);

        uint256 spPpsPre = sp.convertToAssets(1e18);

        // Settle at 100k face value.
        uint256 batchId = svault.nextBatchId();
        vm.startPrank(manager);
        usdr.approve(address(svault), 100_000e18);
        svault.settleRedemption(batchId, 100_000e18);
        vm.stopPrank();
        _verifyInvariants();

        uint256 spPpsPost = sp.convertToAssets(1e18);
        assertGt(spPpsPost, spPpsPre, "S5.4: SP price appreciated");
        // Bonus = 100k - 49k = 51k → distributed pro-rata across all stakers.
        assertEq(svault.pegGapPendingForSP(), 0, "S5.4: pegGap drained");
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.5 — RF auto-stake at TGE seed (verified by setUp)
    // ────────────────────────────────────────────────────────────────────

    function test_S5_5_rfAutoStakeAtTGE() public view {
        // RF is seeded at setUp() with RF_SEED USDr → auto-staked into SP.
        uint256 rfAgaSp = sp.balanceOf(address(rf));
        assertEq(rfAgaSp, BASELINE_SP_SHARES, "S5.5: RF holds 100k USDr-eq agaSP");

        // RF holds ~100% of SP supply at this point.
        assertEq(sp.totalSupply(), rfAgaSp, "S5.5: RF == 100% of SP");
    }

    // ────────────────────────────────────────────────────────────────────
    // S5.6 — Treasury auto-stake after origination fee
    // ────────────────────────────────────────────────────────────────────

    function test_S5_6_treasuryAutoStakeAfterFee() public {
        _seedLp();
        address actor = moderates[0];
        // Borrow 500k → fee = 50bps × 500k = 2500 USDr → Treasury auto-stakes.
        _oneShotLeveragedPosition(actor, T_SRES, 1_000_000e18, 500_000e18);
        _verifyInvariants();

        // Treasury holds 0 USDr (synchronous forward to SP).
        assertEq(usdr.balanceOf(address(treasury)), 0, "S5.6: Treasury USDr == 0");
        // Treasury holds agaSP.
        uint256 tAgaSp = sp.balanceOf(address(treasury));
        assertGt(tAgaSp, 0, "S5.6: Treasury staked");
        // USDr-equivalent of Treasury's agaSP ≈ 2500 (within tolerance).
        uint256 tAgToken = sp.convertToAssets(tAgaSp);
        uint256 tUsdrEq = pool.convertToAssets(tAgToken);
        assertApproxEqAbs(tUsdrEq, 2500e18, 25e18, "S5.6: ~2500 USDr-equivalent");
    }
}

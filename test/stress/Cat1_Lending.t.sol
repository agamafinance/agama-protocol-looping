// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 1 — Lending stress
/// @notice Five scenarios validating the LP supply side. The borrower
///         scenarios live in Cat 2; here we exercise lender flows in
///         isolation (no borrows opened) so the share-price math is
///         determined purely by deposits/withdrawals.
contract Cat1_LendingStressTest is StressBase {
    // ────────────────────────────────────────────────────────────────────
    // S1.1 — Whales deposit (5 wallets, 500k–1M each → ~3.75M aggregate)
    // ────────────────────────────────────────────────────────────────────

    function test_S1_1_whalesDeposit() public {
        uint256[5] memory amts = [uint256(500_000e18), 600_000e18, 750_000e18, 900_000e18, 1_000_000e18];
        uint256 totalDeposited;
        for (uint256 i = 0; i < 5; ++i) {
            _deposit(whales[i], amts[i]);
            totalDeposited += amts[i];
            _verifyInvariants();
        }
        assertEq(
            pool.totalAssets(),
            totalDeposited + BASELINE_TVL,
            "S1.1: TVL == sum(deposits) + RF baseline"
        );
        // Pre-borrow share price unaffected by RF baseline (it staked too).
        for (uint256 i = 0; i < 5; ++i) {
            uint256 redeemable = pool.convertToAssets(pool.balanceOf(whales[i]));
            assertApproxEqAbs(redeemable, amts[i], 1, "S1.1: full redeem parity");
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // S1.2 — Retail deposit (5 wallets, 1k–50k each)
    // ────────────────────────────────────────────────────────────────────

    function test_S1_2_retailDeposit() public {
        uint256[5] memory amts = [uint256(1_000e18), 5_000e18, 12_000e18, 25_000e18, 50_000e18];
        for (uint256 i = 0; i < 5; ++i) {
            _deposit(retails[i], amts[i]);
            _verifyInvariants();
        }
        // Even small retail balances should round-trip cleanly.
        assertEq(pool.totalAssets(), 93_000e18 + BASELINE_TVL, "S1.2: aggregate retail TVL");
    }

    // ────────────────────────────────────────────────────────────────────
    // S1.3 — Concurrent deposits (15 lenders interleaved)
    // ────────────────────────────────────────────────────────────────────
    //   Whales, midcaps and retails deposit in ROUND-ROBIN order. Validates
    //   that interleaving doesn't disturb share-price math (no borrowers
    //   yet, so share price is constant 1.0).
    //   Pre-existing assertion: every participant should redeem to
    //   exactly their deposit.

    function test_S1_3_concurrentDeposits() public {
        for (uint256 i = 0; i < 5; ++i) {
            _deposit(whales[i], 500_000e18);
            _deposit(midcaps[i], 100_000e18);
            _deposit(retails[i], 10_000e18);
            _verifyInvariants();
        }
        // Verify pull-out parity: every actor should redeem exactly their
        // deposit (within 1 wei, ERC-4626 rounding).
        for (uint256 i = 0; i < 5; ++i) {
            uint256 wAssets = pool.convertToAssets(pool.balanceOf(whales[i]));
            uint256 mAssets = pool.convertToAssets(pool.balanceOf(midcaps[i]));
            uint256 rAssets = pool.convertToAssets(pool.balanceOf(retails[i]));
            assertApproxEqAbs(wAssets, 500_000e18, 1, "S1.3: whale parity");
            assertApproxEqAbs(mAssets, 100_000e18, 1, "S1.3: midcap parity");
            assertApproxEqAbs(rAssets, 10_000e18,  1, "S1.3: retail parity");
        }
        assertEq(pool.totalAssets(), 3_050_000e18 + BASELINE_TVL, "S1.3: aggregate TVL");
    }

    // ────────────────────────────────────────────────────────────────────
    // S1.4 — Withdraw partiel (50% of position)
    // ────────────────────────────────────────────────────────────────────

    function test_S1_4_withdrawPartial() public {
        _deposit(whales[0], 1_000_000e18);
        uint256 preCash = usdr.balanceOf(whales[0]);

        _withdraw(whales[0], 500_000e18);
        _verifyInvariants();

        assertEq(usdr.balanceOf(whales[0]) - preCash, 500_000e18, "S1.4: 500k returned");
        // Remaining position should still be worth 500k.
        uint256 remaining = pool.convertToAssets(pool.balanceOf(whales[0]));
        assertApproxEqAbs(remaining, 500_000e18, 1, "S1.4: 500k still in LP");
        assertEq(pool.totalAssets(), 500_000e18 + BASELINE_TVL, "S1.4: TVL halved + RF");
    }

    // ────────────────────────────────────────────────────────────────────
    // S1.5 — Withdraw total + redeposit
    // ────────────────────────────────────────────────────────────────────

    function test_S1_5_withdrawTotalThenRedeposit() public {
        _deposit(whales[1], 600_000e18);
        // Total exit
        uint256 fullShares = pool.balanceOf(whales[1]);
        vm.prank(whales[1]);
        pool.redeem(fullShares, whales[1], whales[1]);
        _verifyInvariants();

        assertEq(pool.balanceOf(whales[1]), 0, "S1.5: shares burned");
        assertEq(pool.totalAssets(), BASELINE_TVL, "S1.5: TVL = RF baseline only");

        // Redeposit
        _deposit(whales[1], 600_000e18);
        _verifyInvariants();

        // Round trip should be identity (within 1 wei).
        uint256 reAssets = pool.convertToAssets(pool.balanceOf(whales[1]));
        assertApproxEqAbs(reAssets, 600_000e18, 1, "S1.5: redeposit parity");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 7 — Oracle stress
/// @notice Four scenarios validating oracle behaviour: staleness, repeated
///         crashes, recovery, and gradual drift.
contract Cat7_OracleStressTest is StressBase {
    function _seedLpAndPositions() internal {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        _oneShotLeveragedPosition(moderates[0], T_SRES, 100_000e18, 50_000e18);
    }

    // ────────────────────────────────────────────────────────────────────
    // S7.1 — Staleness blocks new exposure but not exits
    // ────────────────────────────────────────────────────────────────────

    function test_S7_1_stalenessBlocksOpens() public {
        _seedLpAndPositions();
        // Default ORACLE_STALENESS_MAX = 24h. Warp 25h forward.
        vm.warp(block.timestamp + 25 hours);

        // New deposit on T_SRES must revert.
        address actor = moderates[1];
        _openVault(actor);
        vm.startPrank(actor);
        tranches[T_SRES].token.approve(address(tranches[T_SRES].adapter), 50_000e18);
        try pool.depositAsset(address(tranches[T_SRES].adapter), abi.encode(uint256(50_000e18))) {
            revert("S7.1: deposit should revert with stale oracle");
        } catch {
            // expected
        }
        vm.stopPrank();

        // The pre-existing borrower can still REPAY (exit path).
        _repay(moderates[0], T_SRES, 10_000e18);
        _verifyInvariants();
    }

    // ────────────────────────────────────────────────────────────────────
    // S7.2 — Multiple crashes (5 successive 10% drops)
    // ────────────────────────────────────────────────────────────────────

    function test_S7_2_multipleCrashes() public {
        _seedLpAndPositions();
        // Senior position at LTV 50%. HF starts ~ 1.7. After 5 × 10% drops
        // (cumulative ~41%): collat = 0.5905 → HF = 0.85*0.5905*100/50 = 1.0038.
        for (uint256 i = 0; i < 5; ++i) {
            _crashOracleBps(T_SRES, 1000);
        }
        uint256 hf = _hf(moderates[0], T_SRES);
        assertGt(hf, 1.0e27, "S7.2: still safe ~HF=1.004");
        assertLt(hf, 1.05e27, "S7.2: but very tight");
    }

    // ────────────────────────────────────────────────────────────────────
    // S7.3 — Recovery (after a crash, oracle restores; HF improves)
    // ────────────────────────────────────────────────────────────────────

    function test_S7_3_oracleRecovery() public {
        _seedLpAndPositions();
        _crashOracleBps(T_SRES, 4000); // 40% drop
        uint256 hfPostCrash = _hf(moderates[0], T_SRES);

        // Restore to 1.0
        _crashOracle(T_SRES, 1e18);
        uint256 hfPostRecovery = _hf(moderates[0], T_SRES);
        assertGt(hfPostRecovery, hfPostCrash, "S7.3: HF improves on recovery");
        assertApproxEqRel(hfPostRecovery, 1.7e27, 5e15, "S7.3: HF restored to ~1.7");
    }

    // ────────────────────────────────────────────────────────────────────
    // S7.4 — Gradual drift (10 × 1% drops over time)
    // ────────────────────────────────────────────────────────────────────

    function test_S7_4_gradualDrift() public {
        _seedLpAndPositions();
        for (uint256 i = 0; i < 10; ++i) {
            // Bump lastUpdate so the oracle stays fresh through the drift.
            vm.warp(block.timestamp + 1 hours);
            _crashOracleBps(T_SRES, 100); // 1% drop
            _verifyInvariants();
        }
        // After 10 × 1% drops (~9.56% total), collat = 0.9044, HF = 0.85*0.9044/0.5 = 1.537.
        uint256 hf = _hf(moderates[0], T_SRES);
        assertApproxEqRel(hf, 1.537e27, 1e16, "S7.4: HF after drift ~1.54");
    }
}

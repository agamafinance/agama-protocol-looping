// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressBase} from "./StressBase.sol";

/// @title Cat 6 — Settlement Vault stress
/// @notice Five scenarios validating batch redemption flows.
contract Cat6_SettlementVaultStressTest is StressBase {
    function _seedLpSpAndLiquidate(uint256 trancheIdx, address actor)
        internal
        returns (uint256 batchId)
    {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        // Open + crash + liquidate
        if (trancheIdx == T_SRES) {
            _oneShotLeveragedPosition(actor, trancheIdx, 100_000e18, 74_000e18);
            _crashOracleBps(trancheIdx, 5000);
        } else {
            _oneShotLeveragedPosition(actor, trancheIdx, 100_000e18, 49_000e18);
            _crashOracleBps(trancheIdx, 2500);
        }
        _liquidate(actor, trancheIdx);
        batchId = svault.nextBatchId();
    }

    // ────────────────────────────────────────────────────────────────────
    // S6.1 — Single batch settlement (face value)
    // ────────────────────────────────────────────────────────────────────

    function test_S6_1_singleBatchSettle() public {
        uint256 batchId = _seedLpSpAndLiquidate(T_JRES, aggressives[0]);
        uint256 pegGap = svault.pegGapPendingForSP();

        vm.startPrank(manager);
        usdr.approve(address(svault), 100_000e18);
        svault.settleRedemption(batchId, 100_000e18);
        vm.stopPrank();
        _verifyInvariants();

        assertEq(svault.pegGapPendingForSP(), 0, "S6.1: pegGap drained");
        assertGt(pegGap, 0, "S6.1: had pegGap to settle");
    }

    // ────────────────────────────────────────────────────────────────────
    // S6.2 — Multiple parallel batches
    // ────────────────────────────────────────────────────────────────────

    function test_S6_2_multipleParallelBatches() public {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        // Three liquidations across three tranches.
        _oneShotLeveragedPosition(aggressives[0], T_JRES, 100_000e18, 49_000e18);
        _oneShotLeveragedPosition(aggressives[1], T_SRES, 100_000e18, 74_000e18);
        _oneShotLeveragedPosition(aggressives[2], T_JDIG, 100_000e18, 49_000e18);

        _crashOracleBps(T_JRES, 5000);
        _crashOracleBps(T_SRES, 5000);
        _crashOracleBps(T_JDIG, 5000);

        _liquidate(aggressives[0], T_JRES);
        _liquidate(aggressives[1], T_SRES);
        _liquidate(aggressives[2], T_JDIG);

        // Three queued batches. Settle each at face value.
        for (uint256 b = 1; b <= 3; ++b) {
            vm.startPrank(manager);
            usdr.approve(address(svault), 100_000e18);
            svault.settleRedemption(b, 100_000e18);
            vm.stopPrank();
            _verifyInvariants();
        }
        assertEq(svault.pegGapPendingForSP(), 0, "S6.2: all batches drained");
    }

    // ────────────────────────────────────────────────────────────────────
    // S6.3 — Variable settlement premium (110 / 105 / 90)
    // ────────────────────────────────────────────────────────────────────
    //   Three liquidations settled at different premium levels.

    function test_S6_3_variablePremium() public {
        for (uint256 i = 0; i < 5; ++i) _deposit(whales[i], 1_000_000e18);
        for (uint256 i = 0; i < 3; ++i) _deposit(midcaps[i], 250_000e18);
        for (uint256 i = 0; i < 8; ++i) _stakeSp(spStakers[i], 250_000e18 * 1e6);

        _oneShotLeveragedPosition(aggressives[0], T_JRES, 100_000e18, 49_000e18);
        _crashOracleBps(T_JRES, 2500);
        _liquidate(aggressives[0], T_JRES);
        uint256 b1 = svault.nextBatchId();

        _oneShotLeveragedPosition(aggressives[1], T_JDIG, 100_000e18, 49_000e18);
        _crashOracleBps(T_JDIG, 2500);
        _liquidate(aggressives[1], T_JDIG);
        uint256 b2 = svault.nextBatchId();

        _oneShotLeveragedPosition(aggressives[2], T_JCON, 100_000e18, 49_000e18);
        _crashOracleBps(T_JCON, 2500);
        _liquidate(aggressives[2], T_JCON);
        uint256 b3 = svault.nextBatchId();

        // Premiums: 110% (over-recovery), 105% (slight bonus), 90% (under-recovery → bad debt to SP).
        vm.startPrank(manager);
        usdr.approve(address(svault), 110_000e18 + 105_000e18 + 90_000e18);
        svault.settleRedemption(b1, 110_000e18);
        svault.settleRedemption(b2, 105_000e18);
        svault.settleRedemption(b3,  90_000e18);
        vm.stopPrank();
        _verifyInvariants();

        assertEq(svault.pegGapPendingForSP(), 0, "S6.3: all settled");
    }

    // ────────────────────────────────────────────────────────────────────
    // S6.4 — Stale batch 60d emergency in-kind redemption
    // ────────────────────────────────────────────────────────────────────

    function test_S6_4_staleBatchEmergency() public {
        uint256 batchId = _seedLpSpAndLiquidate(T_JRES, aggressives[0]);

        // The agaSP snapshot is read at the batch's `snapshotBlock` (the
        // block the seizure was queued). Advance the chain past that snapshot
        // before the emergency claim so ERC-5805 doesn't reject "future"
        // lookups, and warp time forward so the stale window has elapsed.
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + 61 days);

        // Pick a holder with sizeable agaSP.
        address holder = whales[0];
        uint256 agaSp = sp.balanceOf(holder);
        assertGt(agaSp, 0, "S6.4: holder has stake");

        svault.emergencyDistributeInKind(batchId, holder);
        _verifyInvariants();
        // Subsequent claim from same holder must revert.
        try svault.emergencyDistributeInKind(batchId, holder) {
            revert("S6.4: double-claim should revert");
        } catch {
            // expected
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // S6.5 — Replace manager (governance hatch)
    // ────────────────────────────────────────────────────────────────────

    function test_S6_5_replaceManager() public {
        address newManager = address(0xBADBAD);
        // Mint USDr to new manager to settle.
        vm.prank(admin);
        usdr.mint(newManager, 1_000_000e18);

        vm.prank(admin);
        svault.grantManager(newManager);

        // Run a liquidation, settle with new manager.
        uint256 batchId = _seedLpSpAndLiquidate(T_JRES, aggressives[0]);
        vm.startPrank(newManager);
        usdr.approve(address(svault), 100_000e18);
        svault.settleRedemption(batchId, 100_000e18);
        vm.stopPrank();
        _verifyInvariants();

        assertEq(svault.pegGapPendingForSP(), 0, "S6.5: settled by new manager");
    }
}

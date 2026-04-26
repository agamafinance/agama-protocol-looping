// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReserveLogic} from "src/libs/ReserveLogic.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";
import {WadRayMath} from "src/libs/WadRayMath.sol";

/// @dev Storage-bound harness so the library can act on `storage` ReserveData.
contract ReserveLogicHarness {
    using ReserveLogic for ReserveLogic.ReserveData;

    ReserveLogic.ReserveData internal R;

    function init() external {
        R.init();
    }

    function updateState() external {
        R.updateState();
    }

    function updateRates(IRM.Params memory p, uint256 cash, uint256 debt, uint256 rf) external {
        R.updateInterestRates(p, cash, debt, rf);
    }

    function getNormalizedIncome() external view returns (uint256) {
        return R.getNormalizedIncome();
    }

    function getNormalizedDebt() external view returns (uint256) {
        return R.getNormalizedDebt();
    }

    function snapshot()
        external
        view
        returns (uint256 liqIdx, uint256 usageIdx, uint256 lr, uint256 br, uint256 lastUpd)
    {
        return (R.liquidityIndex, R.usageIndex, R.currentLiquidityRate, R.currentBorrowRate, R.lastUpdate);
    }
}

contract ReserveLogicTest is Test {
    uint256 internal constant RAY = WadRayMath.RAY;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    ReserveLogicHarness internal h;

    function setUp() public {
        h = new ReserveLogicHarness();
        h.init();
    }

    // ---- init produces unit indices and current timestamp -----------------

    function test_init_setsUnitIndices() public view {
        (uint256 liq, uint256 usage,,, uint256 t) = h.snapshot();
        assertEq(liq, RAY);
        assertEq(usage, RAY);
        assertEq(t, block.timestamp);
    }

    // ---- No time elapsed → no index motion --------------------------------

    function test_updateState_sameBlock_noop() public {
        h.updateState();
        (uint256 liq, uint256 usage,,, uint256 t) = h.snapshot();
        assertEq(liq, RAY);
        assertEq(usage, RAY);
        assertEq(t, block.timestamp);
    }

    // ---- updateInterestRates writes the new rates ------------------------

    function test_updateRates_atKinkUtil() public {
        IRM.Params memory P = IRM.defaults();
        // 80% utilization → borrow 10%, lender 7.2% at rf=10%
        h.updateRates(P, 200e18, 800e18, 1000);
        (,, uint256 lr, uint256 br,) = h.snapshot();
        assertApproxEqAbs(br, 0.1e27, 1e22);
        assertApproxEqAbs(lr, 0.072e27, 1e22);
    }

    // ---- Index growth after time advance with non-zero rates -------------

    function test_indexGrowth_afterOneYear_atKink() public {
        IRM.Params memory P = IRM.defaults();
        h.updateRates(P, 200e18, 800e18, 1000);

        // Project forward 1 year
        uint256 t0 = block.timestamp;
        vm.warp(t0 + SECONDS_PER_YEAR);

        // Borrow index ≈ 1.10 (10% APR, linear)
        assertApproxEqAbs(h.getNormalizedDebt(), 1.1e27, 1e22);
        // Liquidity index ≈ 1.072 (7.2% APR)
        assertApproxEqAbs(h.getNormalizedIncome(), 1.072e27, 1e22);
    }

    function test_updateState_persistsProjection() public {
        IRM.Params memory P = IRM.defaults();
        h.updateRates(P, 200e18, 800e18, 1000);

        vm.warp(block.timestamp + SECONDS_PER_YEAR / 2);
        h.updateState();

        (uint256 liq, uint256 usage,,, uint256 t) = h.snapshot();
        // 6 months at 10% borrow ≈ 1.05 borrow index
        assertApproxEqAbs(usage, 1.05e27, 1e22);
        assertApproxEqAbs(liq, 1.036e27, 1e22);
        assertEq(t, block.timestamp);
    }

    // ---- Idempotency: updateState in same block returns early ------------

    function test_updateState_isIdempotent() public {
        IRM.Params memory P = IRM.defaults();
        h.updateRates(P, 200e18, 800e18, 1000);
        vm.warp(block.timestamp + 1 days);
        h.updateState();
        (, uint256 u1,,,) = h.snapshot();
        // call again same block: no further movement
        h.updateState();
        (, uint256 u2,,,) = h.snapshot();
        assertEq(u1, u2);
    }

    // ---- Compounded growth: two half-years vs one full year --------------
    // Linear approximation: not perfectly multiplicative across windows, but
    // close to compound. We assert the error stays bounded.

    function test_compoundedGrowth_acrossWindows() public {
        IRM.Params memory P = IRM.defaults();
        h.updateRates(P, 200e18, 800e18, 1000);

        vm.warp(block.timestamp + SECONDS_PER_YEAR / 2);
        h.updateState();
        vm.warp(block.timestamp + SECONDS_PER_YEAR / 2);
        // Note: rates not re-updated in between → uses same rate the whole year.
        // Two half-year linear steps multiply: (1 + r/2) × (1 + r/2) = 1 + r + r²/4
        // For r=10%: 1.1025 vs 1.10 single step → 25 bps relative drift.
        uint256 borrowed = h.getNormalizedDebt();
        // Expect ≈ 1.1025e27 (compound) vs 1.10e27 (one-shot linear)
        assertGt(borrowed, 1.1e27);
        assertLt(borrowed, 1.105e27);
    }
}

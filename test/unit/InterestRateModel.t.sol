// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";
import {WadRayMath} from "src/libs/WadRayMath.sol";

contract IRMHarness {
    function utilization(uint256 cash, uint256 borrowed) external pure returns (uint256) {
        return IRM.utilization(cash, borrowed);
    }

    function borrowRate(IRM.Params memory p, uint256 u) external pure returns (uint256) {
        return IRM.borrowRate(p, u);
    }

    function getRates(IRM.Params memory p, uint256 cash, uint256 borrowed, uint256 rf)
        external
        pure
        returns (uint256, uint256)
    {
        return IRM.getRates(p, cash, borrowed, rf);
    }

    function validate(IRM.Params memory p) external pure {
        IRM.validate(p);
    }

    function lenderRate(uint256 br, uint256 u, uint256 rf) external pure returns (uint256) {
        return IRM.lenderRate(br, u, rf);
    }
}

contract InterestRateModelTest is Test {
    uint256 internal constant RAY = WadRayMath.RAY;

    IRMHarness internal h;
    IRM.Params internal P;

    function setUp() public {
        h = new IRMHarness();
        P = IRM.defaults();
    }

    // ---- Defaults match the doc table -------------------------------------
    // | u    | borrow APY | lender APY (rf=10%) |
    // | 30%  | 5.00%      | 1.35%               |
    // | 50%  | 7.00%      | 3.15%               |
    // | 70%  | 9.00%      | 5.67%               |
    // | 80%  | 10.00%     | 7.20%               |
    // | 90%  | 40.00%     | 32.40%              |
    // | 95%  | 55.00%     | 47.025%             |

    function _rateAtUtil(uint256 utilRay) internal view returns (uint256 br, uint256 lr) {
        // synthesize cash/borrowed pair giving the target utilization.
        // borrowed = utilRay; total = RAY → cash = RAY - utilRay
        uint256 borrowed = utilRay;
        uint256 cash = RAY - utilRay;
        return h.getRates(P, cash, borrowed, 1000);
    }

    function test_borrowRate_atKnownUtilizations() public view {
        (uint256 br30,) = _rateAtUtil(0.3e27);
        assertApproxEqAbs(br30, 0.05e27, 1e22, "30%");

        (uint256 br50,) = _rateAtUtil(0.5e27);
        assertApproxEqAbs(br50, 0.07e27, 1e22, "50%");

        (uint256 br70,) = _rateAtUtil(0.7e27);
        assertApproxEqAbs(br70, 0.09e27, 1e22, "70%");

        (uint256 br80,) = _rateAtUtil(0.8e27);
        assertApproxEqAbs(br80, 0.1e27, 1e22, "80% (kink)");

        (uint256 br90,) = _rateAtUtil(0.9e27);
        assertApproxEqAbs(br90, 0.4e27, 1e22, "90%");

        (uint256 br95,) = _rateAtUtil(0.95e27);
        assertApproxEqAbs(br95, 0.55e27, 1e22, "95%");
    }

    function test_lenderRate_atKnownUtilizations() public view {
        (, uint256 lr30) = _rateAtUtil(0.3e27);
        assertApproxEqAbs(lr30, 0.0135e27, 1e22, "30%");

        (, uint256 lr80) = _rateAtUtil(0.8e27);
        assertApproxEqAbs(lr80, 0.072e27, 1e22, "80%");

        (, uint256 lr95) = _rateAtUtil(0.95e27);
        assertApproxEqAbs(lr95, 0.470_25e27, 1e22, "95%");
    }

    // ---- Edge utilizations -------------------------------------------------

    function test_utilization_zeroPool_returnsZero() public view {
        assertEq(h.utilization(0, 0), 0);
    }

    function test_borrowRate_atZeroUtil_returnsBase() public view {
        assertEq(h.borrowRate(P, 0), P.baseRate);
    }

    function test_borrowRate_atFullUtil_capped() public view {
        // u = RAY → borrow = base + slope1 + slope2 = 2% + 8% + 60% = 70%
        uint256 br = h.borrowRate(P, RAY);
        assertApproxEqAbs(br, 0.7e27, 1e22);
    }

    function test_lenderRate_zeroUtil_isZero() public view {
        (, uint256 lr) = h.getRates(P, 1_000_000e18, 0, 1000);
        assertEq(lr, 0);
    }

    // ---- Validate ----------------------------------------------------------

    function test_validate_acceptsDefaults() public view {
        h.validate(P);
    }

    function test_validate_rejectsZeroOptimal() public {
        IRM.Params memory bad = P;
        bad.optimalUtil = 0;
        vm.expectRevert(IRM.InvalidParams.selector);
        h.validate(bad);
    }

    function test_validate_rejectsOptimalAtOrAbove100() public {
        IRM.Params memory bad = P;
        bad.optimalUtil = RAY;
        vm.expectRevert(IRM.InvalidParams.selector);
        h.validate(bad);
    }

    function test_lenderRate_rejectsHugeReserveFactor() public {
        vm.expectRevert(IRM.InvalidReserveFactor.selector);
        h.lenderRate(0.1e27, 0.8e27, 10_001);
    }

    // ---- Monotonicity fuzz (borrowRate non-decreasing in u) ---------------

    function testFuzz_borrowRate_monotonic(uint256 uA, uint256 uB) public view {
        uA = bound(uA, 0, RAY);
        uB = bound(uB, 0, RAY);
        if (uA > uB) (uA, uB) = (uB, uA);

        uint256 brA = h.borrowRate(P, uA);
        uint256 brB = h.borrowRate(P, uB);
        assertLe(brA, brB);
    }

    /// @dev At the kink, both branches should agree.
    function test_borrowRate_continuousAtKink() public view {
        uint256 brBelow = h.borrowRate(P, P.optimalUtil - 1);
        uint256 brAt = h.borrowRate(P, P.optimalUtil);
        uint256 brAbove = h.borrowRate(P, P.optimalUtil + 1);
        // continuity: 1 ray-unit step in u shouldn't blow up
        assertLe(brAt - brBelow, 1e10); // < 1e-17 % deviation
        assertLe(brAbove - brAt, 1e15); // slope2 > slope1, larger jump but still sane
    }
}

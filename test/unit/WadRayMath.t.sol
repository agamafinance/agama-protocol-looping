// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WadRayMath} from "src/libs/WadRayMath.sol";

/// @dev Harness exposes the library as external functions so vm.expectRevert
///      catches reverts at the proper call depth.
contract WadRayMathHarness {
    function rayMul(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayMul(a, b);
    }

    function rayDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.rayDiv(a, b);
    }

    function wadMul(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.wadMul(a, b);
    }

    function wadDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return WadRayMath.wadDiv(a, b);
    }

    function wadToRay(uint256 a) external pure returns (uint256) {
        return WadRayMath.wadToRay(a);
    }

    function rayToWad(uint256 a) external pure returns (uint256) {
        return WadRayMath.rayToWad(a);
    }
}

contract WadRayMathTest is Test {
    using WadRayMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    WadRayMathHarness internal h;

    function setUp() public {
        h = new WadRayMathHarness();
    }

    // ---- Identity & zero ---------------------------------------------------

    function test_rayMul_byRay_isIdentity() public pure {
        assertEq(uint256(123_456_789).rayMul(RAY), 123_456_789);
    }

    function test_rayMul_zero() public pure {
        assertEq(uint256(0).rayMul(RAY), 0);
        assertEq(RAY.rayMul(0), 0);
    }

    function test_rayDiv_byRay_isIdentity() public pure {
        assertEq(uint256(987_654).rayDiv(RAY), 987_654);
    }

    function test_wadMul_byWad_isIdentity() public pure {
        assertEq(uint256(42).wadMul(WAD), 42);
    }

    function testFuzz_rayMul_preservesIdentity(uint128 a) public pure {
        assertEq(uint256(a).rayMul(RAY), uint256(a));
    }

    // ---- Reverts (via harness so expectRevert catches external revert) ----

    function test_rayDiv_byZero_reverts() public {
        vm.expectRevert(WadRayMath.DivByZero.selector);
        h.rayDiv(1, 0);
    }

    function test_wadDiv_byZero_reverts() public {
        vm.expectRevert(WadRayMath.DivByZero.selector);
        h.wadDiv(1, 0);
    }

    function test_rayMul_overflow_reverts() public {
        vm.expectRevert(WadRayMath.MulOverflow.selector);
        h.rayMul(type(uint256).max, 2);
    }

    function test_wadToRay_overflow_reverts() public {
        vm.expectRevert(WadRayMath.MulOverflow.selector);
        h.wadToRay(type(uint256).max);
    }

    // ---- Commutativity -----------------------------------------------------

    function testFuzz_rayMul_commutative(uint128 a, uint128 b) public pure {
        assertEq(uint256(a).rayMul(b), uint256(b).rayMul(a));
    }

    function testFuzz_wadMul_commutative(uint128 a, uint128 b) public pure {
        assertEq(uint256(a).wadMul(b), uint256(b).wadMul(a));
    }

    // ---- Roundtrip with proper precision bounds ----------------------------
    //
    // For half-up fixed-point: rayDiv(rayMul(a, b), b) loses precision bounded by
    //   error ≤ ceil(b / RAY) + 1   (approximately)
    // The intuition: rayMul rounds a*b/RAY to nearest integer; when divided back
    // the residual error scales with the truncation factor of the multiplication.
    // We assert a tight, sound bound: error ≤ 2 when result fits.

    function testFuzz_rayMul_roundtripWhenIdentityFactor(uint128 aSmall) public pure {
        // Roundtrip with b == RAY is exact: a * RAY / RAY = a.
        uint256 a = uint256(aSmall);
        uint256 m = a.rayMul(RAY);
        assertEq(m.rayDiv(RAY), a);
    }

    /// @dev Half-up rounding error analysis for rayDiv(rayMul(a, b), b):
    ///        m    = round(a*b/RAY)        with |m - a*b/RAY| ≤ 0.5
    ///        back = round(m*RAY/b)        with |back - m*RAY/b| ≤ 0.5
    ///      Substituting:
    ///        |back - a| ≤ 0.5 + 0.5 * RAY/b
    ///      So a tight integer upper bound is errorBound = RAY/(2*b) + 2.
    ///      For b ≥ RAY this collapses to ≤ 2 (compound rounding).
    function testFuzz_rayMulDiv_roundtripBounded(uint128 aSeed, uint128 bSeed) public pure {
        uint256 a = bound(uint256(aSeed), RAY, type(uint128).max);
        uint256 b = bound(uint256(bSeed), 1, type(uint128).max);

        uint256 m = a.rayMul(b);
        uint256 back = m.rayDiv(b);

        uint256 diff = back > a ? back - a : a - back;
        uint256 errorBound = RAY / (2 * b) + 2;
        assertLe(diff, errorBound);
    }

    function testFuzz_wadMulDiv_roundtripBounded(uint128 aSeed, uint128 bSeed) public pure {
        uint256 a = bound(uint256(aSeed), WAD, type(uint128).max);
        uint256 b = bound(uint256(bSeed), 1, type(uint128).max);

        uint256 m = a.wadMul(b);
        uint256 back = m.wadDiv(b);

        uint256 diff = back > a ? back - a : a - back;
        uint256 errorBound = WAD / (2 * b) + 2;
        assertLe(diff, errorBound);
    }

    // ---- wad <-> ray casting -----------------------------------------------

    function test_wadToRay_back_isIdentity() public pure {
        uint256 w = 123_456_789_123_456_789;
        assertEq(WadRayMath.rayToWad(WadRayMath.wadToRay(w)), w);
    }

    function test_rayToWad_halfUp_atExactHalf() public pure {
        // remainder == HALF_WAD_RAY_RATIO (5e8) → rounds up to 1
        assertEq(WadRayMath.rayToWad(5e8), 1);
        // remainder just below half (4.99...e8) → rounds down to 0
        assertEq(WadRayMath.rayToWad(5e8 - 1), 0);
    }

    function testFuzz_wadToRay_roundtrip(uint128 a) public pure {
        uint256 r = WadRayMath.wadToRay(a);
        assertEq(WadRayMath.rayToWad(r), uint256(a));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";

/// @title AdapterRiskParams
/// @notice Phase B hardening: AmFiAdapter constructor must reject bogus
///         risk parameters, since these are immutable for the adapter's
///         lifetime.
contract AdapterRiskParamsTest is Test {
    address admin = address(0xA11CE);
    address pool = address(0x1234);
    MockAMFI amfi;
    MockOracle oracle;

    function setUp() public {
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);
    }

    function _deploy(uint256 maxLtv, uint256 lt, uint256 bonus) internal returns (AmFiAdapter) {
        return new AmFiAdapter(pool, amfi, oracle, admin, maxLtv, lt, bonus, 24 hours);
    }

    function test_validParams_deploys() public {
        AmFiAdapter a = _deploy(7000, 8000, 500);
        assertEq(a.MAX_LTV(), 7000);
        assertEq(a.LIQUIDATION_THRESHOLD(), 8000);
        assertEq(a.LIQUIDATION_BONUS(), 500);
    }

    function test_ltvAboveLT_reverts() public {
        // LTV must be strictly below LT.
        vm.expectRevert(AmFiAdapter.InvalidRiskParams.selector);
        _deploy(8000, 8000, 500);
    }

    function test_ltvWayAboveLT_reverts() public {
        vm.expectRevert(AmFiAdapter.InvalidRiskParams.selector);
        _deploy(9000, 8000, 500);
    }

    function test_ltAboveDenom_reverts() public {
        vm.expectRevert(AmFiAdapter.InvalidRiskParams.selector);
        _deploy(7000, 11_000, 500); // LT > 10_000
    }

    function test_bonusAboveDenom_reverts() public {
        vm.expectRevert(AmFiAdapter.InvalidRiskParams.selector);
        _deploy(7000, 8000, 11_000); // bonus > 10_000
    }

    function test_extremesAtEdge_deploys() public {
        // LTV = 9999, LT = 10000, bonus = 10000 — all at upper bounds
        AmFiAdapter a = _deploy(9_999, 10_000, 10_000);
        assertEq(a.MAX_LTV(), 9_999);
    }
}

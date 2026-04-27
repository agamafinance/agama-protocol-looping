// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockTrancheToken} from "src/mocks/MockTrancheToken.sol";

/// @title TrancheToken
/// @notice Validates the V2 multi-tranche generic token mock: per-tranche
///         metadata, configurable APR accrual, public unrestricted mint.
contract TrancheTokenTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);

    function _deploy(uint256 aprRay, string memory pool, string memory tranche)
        internal
        returns (MockTrancheToken)
    {
        return new MockTrancheToken("Token", "TKN", pool, tranche, aprRay, admin);
    }

    function test_metadata_set() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        assertEq(t.poolName(), "Resolvi");
        assertEq(t.trancheType(), "Senior");
        assertEq(t.aprRay(), 0.12e27);
        assertEq(t.admin(), admin);
        assertEq(t.decimals(), 18);
    }

    function test_pricePerShare_grows_at_apr() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        assertEq(t.pricePerShare(), 1e18);
        vm.warp(block.timestamp + 365 days / 2);
        // 1e18 * (1 + 0.12 * 0.5) = 1.06e18
        assertApproxEqAbs(t.pricePerShare(), 1.06e18, 1e10);
    }

    function test_senior_vs_junior_aprDifference() public {
        MockTrancheToken senior = _deploy(0.12e27, "Resolvi", "Senior");
        MockTrancheToken junior = _deploy(0.24e27, "Resolvi", "Junior");

        vm.warp(block.timestamp + 365 days);
        // Senior +12%, Junior +24%
        assertApproxEqAbs(senior.pricePerShare(), 1.12e18, 1e15);
        assertApproxEqAbs(junior.pricePerShare(), 1.24e18, 1e15);
    }

    function test_mint_publicAnyone() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        vm.prank(bob);
        t.mint(bob, 1000e18);
        assertEq(t.balanceOf(bob), 1000e18);
    }

    function test_setAccrual_byAdmin() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        vm.prank(admin);
        t.setAccrual(0.2e27);
        assertEq(t.aprRay(), 0.2e27);
    }

    function test_setAccrual_unauthorized_reverts() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        vm.prank(bob);
        vm.expectRevert(MockTrancheToken.OnlyAdmin.selector);
        t.setAccrual(0.2e27);
    }

    function test_setPricePerShare_demoCheat() public {
        // Crash the tranche to 0.7x par — simulate stress for liquidation demo.
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Junior");
        vm.prank(admin);
        t.setPricePerShare(0.7e18);
        assertEq(t.pricePerShare(), 0.7e18);
    }

    function test_setPricePerShare_zero_reverts() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        vm.prank(admin);
        vm.expectRevert(MockTrancheToken.InvalidPrice.selector);
        t.setPricePerShare(0);
    }

    function test_balance_isStatic_evenWithAccrual() public {
        MockTrancheToken t = _deploy(0.24e27, "Resolvi", "Junior");
        vm.prank(bob);
        t.mint(bob, 1_000_000e18);
        uint256 b1 = t.balanceOf(bob);

        vm.warp(block.timestamp + 365 days);
        uint256 b2 = t.balanceOf(bob);
        assertEq(b1, b2, "ERC20 balance is static; yield is on pricePerShare()");
        assertApproxEqAbs(t.pricePerShare(), 1.24e18, 1e15);
    }

    function test_burn_self() public {
        MockTrancheToken t = _deploy(0.12e27, "Resolvi", "Senior");
        vm.prank(bob);
        t.mint(bob, 100e18);
        vm.prank(bob);
        t.burn(40e18);
        assertEq(t.balanceOf(bob), 60e18);
    }
}

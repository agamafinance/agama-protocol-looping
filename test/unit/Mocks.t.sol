// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MocksTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;

    uint256 constant APR_16 = 0.16e27;

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, APR_16);
        oracle = new MockOracle(admin, 1e18);
    }

    // ---- USDr / AMFI standard ERC20 --------------------------------------

    function test_usdr_decimals_is18() public view {
        assertEq(usdr.decimals(), 18);
    }

    function test_amfi_decimals_is18() public view {
        assertEq(amfi.decimals(), 18);
    }

    function test_usdr_mint_byMinter() public {
        vm.prank(admin);
        usdr.mint(bob, 1000e18);
        assertEq(usdr.balanceOf(bob), 1000e18);
    }

    function test_usdr_mint_unauthorized_reverts() public {
        bytes32 minterRole = usdr.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, minterRole)
        );
        vm.prank(bob);
        usdr.mint(bob, 1e18);
    }

    function test_usdr_burn_self() public {
        vm.prank(admin);
        usdr.mint(bob, 100e18);
        vm.prank(bob);
        usdr.burn(40e18);
        assertEq(usdr.balanceOf(bob), 60e18);
    }

    // ---- AMFI yield-bearing -----------------------------------------------

    function test_amfi_pricePerShare_initial_is1e18() public view {
        assertEq(amfi.pricePerShare(), 1e18);
    }

    function test_amfi_pricePerShare_grows_at_16APR() public {
        vm.warp(block.timestamp + 365 days / 2);
        // 1e18 * (1 + 0.16 * 0.5) = 1.08e18
        assertApproxEqAbs(amfi.pricePerShare(), 1.08e18, 1e10);
    }

    function test_amfi_balance_isStatic_evenWithAccrual() public {
        vm.prank(admin);
        amfi.mint(bob, 1_000_000e18);
        uint256 b1 = amfi.balanceOf(bob);

        vm.warp(block.timestamp + 365 days);
        uint256 b2 = amfi.balanceOf(bob);
        assertEq(b1, b2, "ERC20 balance must not rebase; yield is on pricePerShare()");
        // but pricePerShare has grown
        assertApproxEqAbs(amfi.pricePerShare(), 1.16e18, 1e15);
    }

    function test_amfi_setAccrual_reAnchors() public {
        vm.warp(block.timestamp + 365 days);
        // pricePerShare ~ 1.16e18
        vm.prank(admin);
        amfi.setAccrual(0); // pause accrual
        uint256 frozen = amfi.pricePerShare();

        vm.warp(block.timestamp + 365 days);
        assertEq(amfi.pricePerShare(), frozen);
    }

    function test_amfi_setPricePerShare_jumps() public {
        vm.prank(admin);
        amfi.setPricePerShare(0.7e18); // crash
        assertEq(amfi.pricePerShare(), 0.7e18);
    }

    function test_amfi_setPricePerShare_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(MockAMFI.InvalidPrice.selector);
        amfi.setPricePerShare(0);
    }

    function test_amfi_setAccrual_unauthorizedReverts() public {
        vm.prank(bob);
        vm.expectRevert();
        amfi.setAccrual(0.2e27);
    }

    // ---- Oracle ------------------------------------------------------------

    function test_oracle_initialPrice() public view {
        assertEq(oracle.getPrice(), 1e18);
    }

    function test_oracle_setPrice_byOwner() public {
        vm.prank(admin);
        oracle.setPrice(0.7e18);
        assertEq(oracle.getPrice(), 0.7e18);
    }

    function test_oracle_setPrice_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(MockOracle.ZeroPrice.selector);
        oracle.setPrice(0);
    }

    function test_oracle_setPrice_unauthorizedReverts() public {
        vm.prank(bob);
        vm.expectRevert();
        oracle.setPrice(1.5e18);
    }

    function test_oracle_setPrice_bumpsLastUpdate() public {
        uint256 t0 = oracle.lastUpdate();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(admin);
        oracle.setPrice(0.9e18);
        assertEq(oracle.lastUpdate(), t0 + 1 hours);
    }
}

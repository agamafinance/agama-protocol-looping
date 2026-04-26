// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoFaucet} from "src/mocks/DemoFaucet.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";

contract DemoFaucetTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAA0);

    MockUSDr usdr;
    MockAMFI amfi;
    DemoFaucet faucet;

    uint256 constant USDR_DRIP = 1_000_000e18; // 1M
    uint256 constant AMFI_DRIP = 1_000_000e18; // 1M
    uint256 constant COOLDOWN = 24 hours;

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        faucet = new DemoFaucet(admin, usdr, amfi, USDR_DRIP, AMFI_DRIP, COOLDOWN);

        // grant MINTER_ROLE to faucet
        bytes32 minter = usdr.MINTER_ROLE();
        vm.startPrank(admin);
        usdr.grantRole(minter, address(faucet));
        amfi.grantRole(minter, address(faucet));
        vm.stopPrank();
    }

    function test_drip_mintsToCaller() public {
        vm.prank(bob);
        faucet.drip();
        assertEq(usdr.balanceOf(bob), USDR_DRIP);
        assertEq(amfi.balanceOf(bob), AMFI_DRIP);
    }

    function test_drip_secondTime_inCooldown_reverts() public {
        vm.prank(bob);
        faucet.drip();

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(DemoFaucet.CooldownActive.selector, 23 hours));
        vm.prank(bob);
        faucet.drip();
    }

    function test_drip_afterCooldown_succeeds() public {
        vm.prank(bob);
        faucet.drip();

        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(bob);
        faucet.drip();
        assertEq(usdr.balanceOf(bob), USDR_DRIP * 2);
    }

    function test_drip_independent_perAddress() public {
        vm.prank(bob);
        faucet.drip();
        vm.prank(carol);
        faucet.drip();
        assertEq(usdr.balanceOf(carol), USDR_DRIP);
    }

    function test_secondsUntilNextDrip() public {
        assertEq(faucet.secondsUntilNextDrip(bob), 0);
        vm.prank(bob);
        faucet.drip();
        assertEq(faucet.secondsUntilNextDrip(bob), COOLDOWN);
        vm.warp(block.timestamp + 1 hours);
        assertEq(faucet.secondsUntilNextDrip(bob), 23 hours);
    }

    function test_setDripAmounts_byOwner() public {
        vm.prank(admin);
        faucet.setDripAmounts(2000e18, 500e18);
        vm.prank(bob);
        faucet.drip();
        assertEq(usdr.balanceOf(bob), 2000e18);
        assertEq(amfi.balanceOf(bob), 500e18);
    }

    function test_setCooldown_byOwner() public {
        vm.prank(admin);
        faucet.setCooldown(1 hours);
        vm.prank(bob);
        faucet.drip();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob);
        faucet.drip();
        assertEq(usdr.balanceOf(bob), USDR_DRIP * 2);
    }

    function test_setDripAmounts_unauthorizedReverts() public {
        vm.prank(bob);
        vm.expectRevert();
        faucet.setDripAmounts(1, 1);
    }
}

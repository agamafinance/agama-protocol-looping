// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S4_StabilityPoolDirect
/// @notice V1: deposit and redeem are direct ERC-4626 operations. The only
///         exit guard is the same-block protection. No ticket, no timelock.
contract S4StabilityPoolDirectTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xEEE);

    MockUSDr usdr;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool =
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Yield", "agYLD", IRM.defaults(), true);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);

        vm.startPrank(admin);
        usdr.mint(bob, 1_000_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e18, bob);
        vm.stopPrank();
    }

    function _bobStakes(uint256 amount) internal {
        vm.startPrank(bob);
        pool.approve(address(sp), amount);
        sp.deposit(amount, bob);
        vm.stopPrank();
    }

    // ---- Stake / redeem direct ---------------------------------------

    function test_depositMintsAgaSP_oneToOneAtZeroUtil() public {
        _bobStakes(100_000e18);
        assertEq(sp.balanceOf(bob), 100_000e18);
    }

    function test_request_then_claim_returnsAgYLD() public {
        _bobStakes(100_000e18);
        vm.roll(block.number + 1);

        vm.prank(bob);
        uint256 reqId = sp.requestUnstake(50_000e18);

        // Before cooldown: claim reverts.
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.CooldownNotElapsed.selector);
        sp.claim(reqId);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(bob);
        uint256 assets = sp.claim(reqId);
        assertEq(assets, 50_000e18, "1:1 at zero util");
    }

    // ---- Direct ERC-4626 redeem/withdraw are disabled ------------------

    function test_redeem_disabled() public {
        _bobStakes(100_000e18);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.UseCooldownPath.selector);
        sp.redeem(1e18, bob, bob);
    }

    function test_withdraw_disabled() public {
        _bobStakes(100_000e18);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.UseCooldownPath.selector);
        sp.withdraw(1e18, bob, bob);
    }

    // ---- sagYLD is now ERC-20 vanilla (transferable) -------------------
    //   The cooldown lives in the request queue, not in the token.
    //   Transferring sagYLD during a pending unstake reduces the user's
    //   final claim — covered by the new cooldown test suite.

    function test_transfer_succeeds() public {
        _bobStakes(100_000e18);
        uint256 before = sp.balanceOf(bob);
        vm.prank(bob);
        sp.transfer(eve, 1);
        assertEq(sp.balanceOf(bob), before - 1);
        assertEq(sp.balanceOf(eve), 1);
    }

    function test_approve_thenTransferFrom_succeeds() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.approve(eve, type(uint256).max);
        uint256 before = sp.balanceOf(bob);
        vm.prank(eve);
        sp.transferFrom(bob, eve, 1);
        assertEq(sp.balanceOf(bob), before - 1);
        assertEq(sp.balanceOf(eve), 1);
    }

    // ---- ERC20Votes auto-self-delegation -----------------------------

    function test_pastVotes_recordedAtDeposit() public {
        vm.roll(100);
        _bobStakes(100_000e18);
        vm.roll(200);

        assertEq(sp.getPastVotes(bob, 99), 0, "no votes before stake block");
        assertEq(sp.getPastVotes(bob, 100), 100_000e18, "votes recorded at stake block");
    }

    // ---- Liquidation entrypoint smoke test ---------------------------

    function test_liquidateBorrower_byNonManager_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        sp.liquidateBorrower(address(0), address(0), address(0), "", 0);
    }
}

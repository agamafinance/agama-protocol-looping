// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

contract S4StabilityPoolTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xEEE);
    address charlie = address(0xC0FFEE);

    MockUSDr usdr;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool =
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Pool", "agUSDr", IRM.defaults(), true);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin, true);

        vm.startPrank(admin);
        usdr.mint(bob, 1_000_000e18);
        usdr.mint(charlie, 1_000_000e18);
        vm.stopPrank();

        // Bob and Charlie each deposit USDr → get agTOKEN
        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e18, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e18, charlie);
        vm.stopPrank();
    }

    // ---- Helpers ---------------------------------------------------------

    function _bobStakes(uint256 amount) internal {
        vm.startPrank(bob);
        pool.approve(address(sp), amount);
        sp.deposit(amount, bob);
        vm.stopPrank();
    }

    // ---- Production parameters & demo flag ------------------------------

    function test_productionTimings_set() public view {
        assertEq(sp.withdrawTimelockDuration(), 30 minutes);
        assertEq(sp.withdrawTimelockDelay(), 2 days);
        assertTrue(sp.isDemoMode());
    }

    function test_setWithdrawTimelock_demoMode_works() public {
        vm.startPrank(admin);
        sp.setWithdrawTimelockDuration(60);
        sp.setWithdrawTimelockDelay(1 hours);
        vm.stopPrank();
        assertEq(sp.withdrawTimelockDuration(), 60);
        assertEq(sp.withdrawTimelockDelay(), 1 hours);
    }

    function test_setWithdrawTimelock_mainnet_reverts() public {
        AgamaStabilityPool main = new AgamaStabilityPool(IERC20(address(pool)), admin, false);
        vm.prank(admin);
        vm.expectRevert(AgamaStabilityPool.OnlyDemoMode.selector);
        main.setWithdrawTimelockDuration(60);
        assertEq(main.withdrawTimelockDuration(), 30 minutes);
    }

    // ---- Soulbound -------------------------------------------------------

    function test_transfer_reverts() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.NonTransferable.selector);
        sp.transfer(eve, 1);
    }

    function test_transferFrom_reverts() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.approve(eve, type(uint256).max); // approve OK (mint/burn-only invariant only on transfer)
        vm.prank(eve);
        vm.expectRevert(AgamaStabilityPool.NonTransferable.selector);
        sp.transferFrom(bob, eve, 1);
    }

    function test_mint_works() public {
        _bobStakes(100_000e18);
        assertEq(sp.balanceOf(bob), 100_000e18, "1:1 mint at zero util");
    }

    // ---- Deposit flow ----------------------------------------------------

    function test_deposit_recordsBlockAndDelegates() public {
        _bobStakes(100_000e18);
        assertEq(sp.depositBlock(bob), block.number);
        // Auto-self-delegation enables historical-balance lookups
        assertEq(sp.delegates(bob), bob);
    }

    function test_deposit_clearsAnyPendingTicket() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        // 2nd deposit should wipe the ticket
        _bobStakes(50_000e18);
        (uint256 amt,,,) = sp.withdrawTimelock(bob);
        assertEq(amt, 0, "ticket cancelled by deposit");
    }

    // ---- Same-block protection ------------------------------------------

    function test_sameBlock_depositThenRedeem_reverts() public {
        _bobStakes(100_000e18);
        // Try to redeem same block (no time advance, no warp): triggers depositBlock guard
        // before the timelock check would fire.
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.CannotDepositAndWithdrawSameBlock.selector);
        sp.redeem(1e18, bob, bob);
    }

    // ---- Withdraw timelock ----------------------------------------------

    function test_redeem_withoutRequest_reverts() public {
        _bobStakes(100_000e18);
        vm.roll(block.number + 1); // bypass same-block
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.NoPendingWithdraw.selector);
        sp.redeem(1e18, bob, bob);
    }

    function test_redeem_beforeReady_reverts() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.WithdrawTimelockNotReady.selector);
        sp.redeem(50_000e18, bob, bob);
    }

    function test_redeem_afterExpire_reverts() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        // Skip past the entire window
        vm.warp(block.timestamp + 30 minutes + 2 days + 1 seconds);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.WithdrawTimelockExpired.selector);
        sp.redeem(50_000e18, bob, bob);
    }

    function test_redeem_inWindow_succeeds() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.roll(block.number + 1);
        vm.prank(bob);
        uint256 assets = sp.redeem(50_000e18, bob, bob);
        assertEq(assets, 50_000e18, "1:1 shares-to-agTOKEN at zero util");
        // Bob should have his agTOKEN back in his wallet
        assertEq(pool.balanceOf(bob), 1_000_000e18 - 100_000e18 + 50_000e18);
    }

    function test_redeem_moreThanRequested_reverts() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(AgamaStabilityPool.WithdrawAmountTooHigh.selector);
        sp.redeem(60_000e18, bob, bob);
    }

    function test_requestWithdraw_zero_cancelsTicket() public {
        _bobStakes(100_000e18);
        vm.prank(bob);
        sp.requestWithdraw(50_000e18);
        vm.prank(bob);
        sp.requestWithdraw(0);
        (uint256 amt,,,) = sp.withdrawTimelock(bob);
        assertEq(amt, 0);
    }

    // ---- ERC20Votes snapshot ---------------------------------------------

    function test_pastVotes_recordedAtDeposit() public {
        vm.roll(100);
        _bobStakes(100_000e18);
        // Stake happens at block 100. Roll to 200 so all reads are unambiguously in the past.
        vm.roll(200);

        assertEq(sp.getPastVotes(bob, 99), 0, "no votes at block 99 (before stake)");
        assertEq(sp.getPastVotes(bob, 100), 100_000e18, "votes recorded at block 100");
        assertEq(sp.balanceOf(bob), 100_000e18, "current balance unchanged");
    }

    // ---- Liquidation entrypoint smoke test (full impl tested in S3 E2E) -

    function test_liquidateBorrower_byNonManager_reverts() public {
        // No manager set, no role granted to bob.
        vm.prank(bob);
        vm.expectRevert();
        sp.liquidateBorrower(address(0), address(0), address(0), "", 0);
    }

    // ---- totalAssets without SettlementVault ----------------------------

    function test_totalAssets_noVault_isAgTokenBalance() public {
        _bobStakes(100_000e18);
        assertEq(sp.totalAssets(), 100_000e18);
    }

    function test_setSettlementVault_byGovernor() public {
        vm.prank(admin);
        sp.setSettlementVault(address(0xBEEF));
        assertEq(sp.settlementVault(), address(0xBEEF));
    }
}

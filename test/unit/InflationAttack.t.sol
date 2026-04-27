// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title InflationAttack
/// @notice Locks in the ERC-4626 inflation-attack mitigation: the LP overrides
///         `_decimalsOffset()` to return 6, raising virtual share count to
///         1e6 and making the canonical donation attack non-economical.
///
/// Attack scenario (without offset):
///   1. Empty pool. Attacker deposits 1 wei USDr → 1 wei agTOKEN minted.
///   2. Attacker donates N USDr directly to the pool (via plain ERC20 transfer).
///   3. Pool now has 1 wei supply, N+1 wei assets.
///   4. Victim deposits M USDr expecting M agTOKEN, but actually gets
///      M * 1 / (N+1) shares — rounded down to 0 if M < N+1 → 100% loss.
///   5. Attacker redeems their 1 wei share for the entire pool.
///
/// With _decimalsOffset = 6, the virtual share count of 1e6 absorbs the
/// donation: even after donating N USDr, the next depositor gets non-zero
/// shares and recovers most of their deposit. Full production mitigation
/// also relies on the post-deploy seed (RF.seed) which grows totalSupply
/// past any plausible donation — but the offset alone protects the
/// worst-case "empty pool + immediate attacker frontrun" scenario.
contract InflationAttackTest is Test {
    address admin = address(0xA11CE);
    address attacker = address(0xBAD);
    address victim = address(0xC0FFEE);

    MockUSDr usdr;
    AgamaLendingPool pool;

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );

        vm.startPrank(admin);
        usdr.mint(attacker, 1_000_000e18);
        usdr.mint(victim, 1_000_000e18);
        vm.stopPrank();
    }

    // ---- Direct verification of the offset --------------------------

    function test_decimalsOffset_isSix() public view {
        assertEq(pool.decimals(), 24, "agTOKEN decimals = USDr decimals + 6");
    }

    // ---- Attack simulation ------------------------------------------

    function test_inflationAttack_victimDepositRecoversFairValue() public {
        // 1. Attacker seeds the pool with 1 wei.
        vm.startPrank(attacker);
        usdr.approve(address(pool), type(uint256).max);
        uint256 attackerShares = pool.deposit(1, attacker);
        vm.stopPrank();
        assertEq(attackerShares, 1e6, "1 wei deposit at offset 6 -> 1e6 shares");

        // 2. Attacker donates 100k USDr directly to the pool (canonical
        //    inflation attack — inflate cash without minting shares).
        uint256 donation = 100_000e18;
        vm.prank(attacker);
        usdr.transfer(address(pool), donation);

        // 3. Victim deposits 1 USDr.
        uint256 victimDeposit = 1e18;
        vm.startPrank(victim);
        usdr.approve(address(pool), type(uint256).max);
        uint256 victimShares = pool.deposit(victimDeposit, victim);
        vm.stopPrank();

        // 4. Without the offset: victimShares would be 0 (rounded down) and
        //    the victim would have lost their entire 1 USDr to the attacker.
        //    With offset = 6: victim still gets non-zero shares and can
        //    redeem most of their deposit.
        assertGt(victimShares, 0, "victim shares non-zero (offset blocked round-down to zero)");

        uint256 victimRecoverable = pool.previewRedeem(victimShares);
        // Victim deposited 1e18 against a 100k-USDr donation grief — worst-
        // case ratio. The offset alone caps the loss; full mitigation in
        // production also relies on an immediate post-deploy seed (RF.seed
        // at TGE) which grows totalSupply far beyond any plausible donation.
        // For this edge case, recovering 90%+ demonstrates the offset is
        // doing meaningful work.
        assertGe(victimRecoverable, victimDeposit * 90 / 100, "victim recovers >= 90% (worst case)");
    }

    function test_inflationAttack_attackerDonationLosesValue() public {
        // The flip side of the offset mitigation: when an attacker donates
        // to inflate share price, they LOSE most of their donation — they
        // can't fully recover it because the virtual share count of 1e6
        // means their 1 wei "share" is half of the (real + virtual) supply.
        // They get back ~50% of their own donation.
        vm.startPrank(attacker);
        usdr.approve(address(pool), type(uint256).max);
        uint256 attackerShares = pool.deposit(1, attacker);
        uint256 donation = 100_000e18;
        usdr.transfer(address(pool), donation);
        vm.stopPrank();

        uint256 attackerRecoverable = pool.previewRedeem(attackerShares);
        // Attacker recovers at most ~50% of their donation — they wasted
        // the other half. This is the cost of trying to grief the pool.
        assertLe(attackerRecoverable, donation * 51 / 100, "attacker recovers <=51%");
        assertGe(attackerRecoverable, donation * 49 / 100, "attacker recovers >=49% (sanity)");
    }

    // ---- Realistic production scenario: post-seed pool --------------

    function test_inflationAttack_afterRfSeed_attackerHasNoLeverage() public {
        // Realistic: a 100k seed (the RF.seed pattern from DemoSetup.s.sol)
        // makes the offset+seed combo immune. Donation needs to dwarf the
        // pool to even register; this test simulates the attack against a
        // post-seed pool.
        vm.startPrank(admin);
        usdr.mint(admin, 100_000e18);
        usdr.approve(address(pool), 100_000e18);
        pool.deposit(100_000e18, admin); // simulates RF.seed
        vm.stopPrank();

        // Attacker tries the donation grief now.
        vm.prank(attacker);
        usdr.transfer(address(pool), 100_000e18);

        // Victim deposits 1 USDr.
        vm.startPrank(victim);
        usdr.approve(address(pool), type(uint256).max);
        uint256 victimShares = pool.deposit(1e18, victim);
        vm.stopPrank();

        uint256 victimRecoverable = pool.previewRedeem(victimShares);
        // With a 100k seed, the attacker's 100k donation only doubles the
        // pool. Victim's loss is bounded by their proportional share of the
        // donation, which is tiny (1e18 / 200_000e18 = 0.0005% of donation).
        assertGe(victimRecoverable, 1e18 * 9990 / 10_000, "post-seed: victim recovers >= 99.9%");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaTreasury} from "src/collectors/Treasury.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";
import {IAgamaPool, IAgamaSP} from "src/interfaces/IAgamaCollectors.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title CollectorWithdraw
/// @notice Locks in the V2 governance unstake surface on the Treasury
///         and ReserveFund: 2-step `requestUnstakeFromSP` → wait cooldown
///         → `claimUnstakeFromSP` (or `claimAndUnwrapToAddress` for the
///         full USDr exit).
contract CollectorWithdrawTest is Test {
    address admin = address(0xA11CE);
    address recipient = address(0xBEEF);
    address attacker = address(0xBAD);

    MockUSDr usdr;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AgamaTreasury treasury;
    AgamaReserveFund rf;

    function setUp() public {
        usdr = new MockUSDr(admin);
        pool =
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Yield", "agYLD", IRM.defaults(), true);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        treasury =
            new AgamaTreasury(admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr)));
        rf = new AgamaReserveFund(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );

        // Seed RF with 100k USDr → auto-staked.
        vm.startPrank(admin);
        usdr.mint(admin, 100_000e18);
        usdr.approve(address(rf), 100_000e18);
        rf.seed(100_000e18);
        // Seed Treasury directly with USDr → auto-staked.
        treasury.grantDepositor(admin);
        usdr.mint(admin, 50_000e18);
        usdr.approve(address(treasury), 50_000e18);
        treasury.deposit(address(usdr), 50_000e18);
        vm.stopPrank();

        // Roll past SP same-block flash-loan guard.
        vm.roll(block.number + 1);
    }

    // ---- ReserveFund 2-step unstake (request + wait + claim) -----------

    function test_rf_request_then_claim_sendsAgYLDToRecipient() public {
        uint256 sagBefore = IERC20(address(sp)).balanceOf(address(rf));
        uint256 agYLDBefore = IERC20(address(pool)).balanceOf(recipient);

        vm.prank(admin);
        uint256 reqId = rf.requestUnstakeFromSP(10_000e18);
        // Cooldown not elapsed → claim reverts.
        vm.prank(admin);
        vm.expectRevert(AgamaStabilityPool.CooldownNotElapsed.selector);
        rf.claimUnstakeFromSP(reqId, recipient);

        // Warp past cooldown.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(admin);
        uint256 agYLDOut = rf.claimUnstakeFromSP(reqId, recipient);

        assertEq(IERC20(address(sp)).balanceOf(address(rf)), sagBefore - 10_000e18, "sagYLD burned");
        assertEq(
            IERC20(address(pool)).balanceOf(recipient), agYLDBefore + agYLDOut, "agYLD to recipient"
        );
        assertGt(agYLDOut, 0, "non-zero agYLD");
    }

    function test_rf_requestUnstakeFromSP_unauthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        rf.requestUnstakeFromSP(1e18);
    }

    function test_rf_governorRoleGranted() public view {
        assertTrue(rf.hasRole(rf.GOVERNOR_ROLE(), admin));
    }

    // ---- Treasury 2-step unstake -------------------------------------

    function test_treasury_request_then_claim_sendsAgYLDToRecipient() public {
        uint256 sagBefore = IERC20(address(sp)).balanceOf(address(treasury));
        uint256 agYLDBefore = IERC20(address(pool)).balanceOf(recipient);

        vm.prank(admin);
        uint256 reqId = treasury.requestUnstakeFromSP(5_000e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(admin);
        uint256 agYLDOut = treasury.claimUnstakeFromSP(reqId, recipient);

        assertEq(IERC20(address(sp)).balanceOf(address(treasury)), sagBefore - 5_000e18);
        assertEq(IERC20(address(pool)).balanceOf(recipient), agYLDBefore + agYLDOut);
        assertGt(agYLDOut, 0);
    }

    function test_treasury_requestUnstakeFromSP_unauthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.requestUnstakeFromSP(1e18);
    }

    // ---- claimAndUnwrapToAddress (full USDr exit) still works ----

    function test_rf_claimAndUnwrapToAddress_returnsUsdrToRecipient() public {
        vm.prank(admin);
        uint256 reqId = rf.requestUnstakeFromSP(20_000e18);
        vm.warp(block.timestamp + 7 days + 1);

        uint256 usdrBefore = usdr.balanceOf(recipient);
        vm.prank(admin);
        rf.claimAndUnwrapToAddress(reqId, recipient);
        assertGt(usdr.balanceOf(recipient), usdrBefore, "USDr to recipient");
    }

    function test_treasury_claimAndUnwrapToAddress_returnsUsdrToRecipient() public {
        vm.prank(admin);
        uint256 reqId = treasury.requestUnstakeFromSP(10_000e18);
        vm.warp(block.timestamp + 7 days + 1);

        uint256 usdrBefore = usdr.balanceOf(recipient);
        vm.prank(admin);
        treasury.claimAndUnwrapToAddress(reqId, recipient);
        assertGt(usdr.balanceOf(recipient), usdrBefore, "USDr to recipient");
    }

    // ---- Phase A: _seeded guard on RF.seed --------------------------

    function test_rf_seed_secondCall_reverts() public {
        // setUp already called rf.seed(100k). Calling again must revert.
        vm.startPrank(admin);
        usdr.mint(admin, 1_000e18);
        usdr.approve(address(rf), 1_000e18);
        vm.expectRevert(AgamaReserveFund.AlreadySeeded.selector);
        rf.seed(1_000e18);
        vm.stopPrank();
        assertTrue(rf.seeded(), "seeded flag set");
    }
}

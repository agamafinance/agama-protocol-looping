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
/// @notice Locks in the post-D2 governance withdraw surface on the Treasury
///         and ReserveFund: direct ERC-4626 redeems, no timelock, no orphan
///         requestWithdraw entrypoint.
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
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Pool", "agUSDr", IRM.defaults(), true);
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

    // ---- ReserveFund.withdrawFromSP (Option A: agTOKEN out) ---------

    function test_rf_withdrawFromSP_sendsAgTokenToRecipient() public {
        uint256 agaSPBefore = IERC20(address(sp)).balanceOf(address(rf));
        uint256 agTokenBefore = IERC20(address(pool)).balanceOf(recipient);

        vm.prank(admin);
        uint256 agSharesOut = rf.withdrawFromSP(10_000e18, recipient);

        assertEq(IERC20(address(sp)).balanceOf(address(rf)), agaSPBefore - 10_000e18, "agaSP burned");
        assertEq(
            IERC20(address(pool)).balanceOf(recipient), agTokenBefore + agSharesOut, "agTOKEN to recipient"
        );
        assertGt(agSharesOut, 0, "non-zero agShares");
    }

    function test_rf_withdrawFromSP_unauthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        rf.withdrawFromSP(1e18, attacker);
    }

    function test_rf_withdrawFromSP_governorRoleGranted() public view {
        assertTrue(rf.hasRole(rf.GOVERNOR_ROLE(), admin));
    }

    // ---- Treasury.withdrawFromSP ------------------------------------

    function test_treasury_withdrawFromSP_sendsAgTokenToRecipient() public {
        uint256 agaSPBefore = IERC20(address(sp)).balanceOf(address(treasury));
        uint256 agTokenBefore = IERC20(address(pool)).balanceOf(recipient);

        vm.prank(admin);
        uint256 agSharesOut = treasury.withdrawFromSP(5_000e18, recipient);

        assertEq(IERC20(address(sp)).balanceOf(address(treasury)), agaSPBefore - 5_000e18);
        assertEq(IERC20(address(pool)).balanceOf(recipient), agTokenBefore + agSharesOut);
        assertGt(agSharesOut, 0);
    }

    function test_treasury_withdrawFromSP_unauthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.withdrawFromSP(1e18, attacker);
    }

    // ---- Existing withdrawToAddress (full USDr exit) still works ----

    function test_rf_withdrawToAddress_returnsUsdrToRecipient() public {
        uint256 usdrBefore = usdr.balanceOf(recipient);

        vm.prank(admin);
        rf.withdrawToAddress(20_000e18, recipient);

        assertGt(usdr.balanceOf(recipient), usdrBefore, "USDr to recipient");
    }

    function test_treasury_withdrawToAddress_returnsUsdrToRecipient() public {
        uint256 usdrBefore = usdr.balanceOf(recipient);

        vm.prank(admin);
        treasury.withdrawToAddress(10_000e18, recipient);

        assertGt(usdr.balanceOf(recipient), usdrBefore, "USDr to recipient");
    }
}

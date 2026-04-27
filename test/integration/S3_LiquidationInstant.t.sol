// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {MockSettlementVault} from "src/mocks/MockSettlementVault.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S3_LiquidationInstant
/// @notice V1 liquidation: single `liquidate` call, no grace period, no
///         init/finalize staging.
contract S3LiquidationInstantTest is Test {
    address admin = address(0xA11CE);
    address manager = address(0x111A);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);
    address charlie = address(0xC0FFEE);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AmFiAdapter adapter;
    LiquidationProxy proxy;
    MockSettlementVault svault;
    DebtToken debt;

    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        proxy = new LiquidationProxy(pool, sp, admin);
        svault = new MockSettlementVault(address(pool), address(sp), IERC20(address(usdr)), admin);
        debt = pool.DEBT_TOKEN();

        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));
        proxy.setManager(manager, true);

        usdr.mint(bob, 10_000_000e18);
        usdr.mint(charlie, 10_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        amfi.mint(charlie, 1_000_000e18);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        pool.approve(address(sp), amount);
        sp.deposit(amount, who);
        vm.stopPrank();
    }

    function _aliceLeveraged(uint256 collateral, uint256 borrowAmount) internal {
        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), collateral);
        pool.depositAsset(address(adapter), abi.encode(collateral));
        pool.borrow(address(adapter), ZERO_DATA, borrowAmount);
        vm.stopPrank();
    }

    function _crashOracleBy(uint256 percentBps) internal {
        uint256 cur = oracle.getPrice();
        vm.prank(admin);
        oracle.setPrice((cur * (10_000 - percentBps)) / 10_000);
    }

    // ---- Tests --------------------------------------------------------

    function test_instantLiquidation_whenHfBelow1() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);

        _aliceLeveraged(1_000_000e18, 700_000e18); // HF = 1.142

        // Crash oracle 30% → HF ≈ 0.8 (< 1)
        _crashOracleBy(3000);
        uint256 hfPost = pool.calculateHealthFactor(address(adapter), alice, ZERO_DATA);
        assertLt(hfPost, 1e27, "HF below 1 after oracle crash");

        // Single-call liquidation. No initiate, no grace, no finalize.
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        assertEq(debt.balanceOf(alice), 0, "Alice debt cleared");
        assertEq(adapter.balanceOf(alice), 0, "Alice collateral seized");
        assertEq(amfi.balanceOf(address(svault)), 1_000_000e18, "RWA in vault");
    }

    function test_liquidate_healthyPosition_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 500_000e18); // 50% LTV — healthy

        vm.expectRevert(AgamaLendingPool.HealthFactorTooHigh.selector);
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    function test_liquidate_zeroDebt_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        // Alice opens vault and deposits collateral but doesn't borrow.
        // SP validates the position has collateral (yes), then LP.liquidate
        // sees zero debt and reverts with NoDebtToLiquidate.
        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), 100_000e18);
        pool.depositAsset(address(adapter), abi.encode(uint256(100_000e18)));
        vm.stopPrank();

        vm.expectRevert(AgamaLendingPool.NoDebtToLiquidate.selector);
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    function test_liquidate_unauthorized_reverts() public {
        _deposit(bob, 2_000_000e18);
        _stake(bob, 2_000_000e18);
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.expectRevert(); // AccessControl revert
        vm.prank(charlie);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    function test_badDebt_redistribution_pathStillWorks() public {
        _deposit(bob, 2_000_000e18);
        // Bob stakes only 100k → SP capacity << Alice's debt
        _stake(bob, 100_000e18);

        _aliceLeveraged(1_000_000e18, 700_000e18);
        // Charlie also borrows so we have someone to redistribute onto
        vm.startPrank(charlie);
        pool.openVaultPosition();
        amfi.approve(address(adapter), 1_000_000e18);
        pool.depositAsset(address(adapter), abi.encode(uint256(1_000_000e18)));
        pool.borrow(address(adapter), ZERO_DATA, 500_000e18);
        vm.stopPrank();

        _crashOracleBy(3000);

        uint256 charlieDebtBefore = debt.balanceOf(charlie);
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // Bad-debt accumulator advanced
        assertGt(pool.bdAccLDebt(), 0, "redistribution triggered");

        // Charlie's actual debt > raw DebtToken balance
        uint256 charlieActualDebt = pool.getPositionScaledDebt(address(adapter), charlie, ZERO_DATA);
        assertGt(charlieActualDebt, charlieDebtBefore);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {MockSettlementVault} from "src/mocks/MockSettlementVault.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S6_OracleCircuitBreaker
/// @notice Per-adapter circuit breaker: when the oracle is stale (no update
///         in `ORACLE_STALENESS_MAX` seconds), new positions and new
///         liquidations revert, but exits keep working — repays clear debt,
///         lender withdraws keep working, full collateral exits work after
///         debt clears.
contract S6OracleCircuitBreakerTest is Test {
    address admin = address(0xA11CE);
    address manager = address(0x111A);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AmFiAdapter adapter;
    LiquidationProxy proxy;
    MockSettlementVault svault;

    bytes constant ZERO_DATA = abi.encode(uint256(0));
    uint256 constant STALE_AGE = 25 hours; // beyond ORACLE_STALENESS_MAX = 24h

    function setUp() public {
        // Ground the test clock at a sane epoch so we can subtract STALE_AGE
        // without underflowing.
        vm.warp(1_700_000_000);

        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        pool =
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Pool", "agUSDr", IRM.defaults(), true);
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        proxy = new LiquidationProxy(pool, sp, admin);
        svault = new MockSettlementVault(address(pool), address(sp), IERC20(address(usdr)), admin);

        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));
        proxy.setManager(manager, true);

        usdr.mint(bob, 5_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        vm.stopPrank();

        // Bob lends 2M, stakes 1M
        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(2_000_000e18, bob);
        pool.approve(address(sp), 1_000_000e18);
        sp.deposit(1_000_000e18, bob);
        vm.stopPrank();

        // Alice opens vault, deposits 500k AMFI, borrows 300k
        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), type(uint256).max);
        pool.depositAsset(address(adapter), abi.encode(uint256(500_000e18)));
        pool.borrow(address(adapter), ZERO_DATA, 300_000e18);
        vm.stopPrank();

        // Make oracle stale
        vm.prank(admin);
        oracle.setLastUpdate(block.timestamp - STALE_AGE);
    }

    // ---- BLOCKED while stale -----------------------------------------

    function test_stale_depositAsset_reverts() public {
        vm.startPrank(alice);
        amfi.approve(address(adapter), 100e18);
        vm.expectRevert(AmFiAdapter.OracleStale.selector);
        pool.depositAsset(address(adapter), abi.encode(uint256(100e18)));
        vm.stopPrank();
    }

    function test_stale_borrow_reverts() public {
        // Borrow path's HF check calls adapter.getAssetValue() which reverts
        // on stale oracle. Use an amount above minBorrowAmount so the
        // staleness check is the binding revert.
        vm.expectRevert(AmFiAdapter.OracleStale.selector);
        vm.prank(alice);
        pool.borrow(address(adapter), ZERO_DATA, 1000e18);
    }

    function test_stale_liquidate_reverts() public {
        // Even if Alice's HF is below 1, liquidation cannot fire while
        // the oracle is stale. (HF check itself reverts via getAssetValue.)
        vm.expectRevert(AmFiAdapter.OracleStale.selector);
        vm.prank(manager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    // ---- ALLOWED while stale (exits) ---------------------------------

    function test_stale_repay_works() public {
        // Alice can repay her debt regardless of oracle state.
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        uint256 debtBefore = pool.DEBT_TOKEN().balanceOf(alice);
        pool.repay(address(adapter), ZERO_DATA, type(uint256).max);
        vm.stopPrank();
        assertEq(pool.DEBT_TOKEN().balanceOf(alice), 0, "debt cleared");
        assertGt(debtBefore, 0);
    }

    function test_stale_lender_withdraw_works() public {
        // Bob can pull his agTOKEN back without an oracle dependency.
        uint256 balBefore = usdr.balanceOf(bob);
        vm.prank(bob);
        pool.withdraw(100_000e18, bob, bob);
        assertEq(usdr.balanceOf(bob) - balBefore, 100_000e18);
    }

    function test_stale_sp_redeem_works() public {
        // SP redeem doesn't touch the oracle.
        vm.roll(block.number + 1);
        vm.prank(bob);
        uint256 assets = sp.redeem(100_000e18, bob, bob);
        assertEq(assets, 100_000e18);
    }

    function test_stale_collateralExit_afterFullRepay_works() public {
        // Full borrower exit: repay → withdrawAsset (debt = 0 path skips
        // the HF check, which would otherwise revert via getAssetValue).
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        pool.repay(address(adapter), ZERO_DATA, type(uint256).max);
        pool.withdrawAsset(address(adapter), abi.encode(uint256(500_000e18)));
        vm.stopPrank();
        assertEq(amfi.balanceOf(alice), 1_000_000e18, "all AMFI back");
    }

    // ---- Recovery: refresh oracle, things resume ---------------------

    function test_freshOracle_resumes_borrow() public {
        vm.prank(admin);
        oracle.setPrice(1e18); // bumps lastUpdate
        vm.prank(alice);
        pool.borrow(address(adapter), ZERO_DATA, 1000e18);
        // No revert
    }
}

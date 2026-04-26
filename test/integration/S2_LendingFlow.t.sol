// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";
import {FeeSink} from "test/helpers/FeeSink.sol";

/// @title S2_LendingFlow
/// @notice End-to-end exercise of the LendingPool + AmFiAdapter wiring:
///         Bob lends USDr, Alice borrows USDr against AMFI collateral, time
///         passes, both close out cleanly with interest accrued.
contract S2LendingFlowTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AmFiAdapter adapter;
    DebtToken debt;
    FeeSink feeSink;

    uint256 constant APR_AMFI = 0.16e27; // 16%
    uint256 constant USDR_INITIAL = 10_000_000e18; // 10M (Bob)
    uint256 constant AMFI_INITIAL = 1_000_000e18; // 1M (Alice)

    function setUp() public {
        // Mocks
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, APR_AMFI);
        oracle = new MockOracle(admin, 1e18); // 1.0 USD per AMFI share at par

        // Pool — demo mode on testnet so timing cheats work in tests.
        IRM.Params memory irm = IRM.defaults();
        pool = new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", irm, true);
        debt = pool.DEBT_TOKEN();

        // Adapter — production V1 risk: MAX_LTV 70%, LT 80%, bonus 5%, staleness 24h.
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);

        // FeeSink stands in for the real FeeCollector in S2 tests.
        feeSink = new FeeSink();

        // Wire: register adapter, set fee recipient (FeeSink for tests)
        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        pool.setFeeRecipient(address(feeSink));
        // Mint to actors
        usdr.mint(bob, USDR_INITIAL);
        amfi.mint(alice, AMFI_INITIAL);
        vm.stopPrank();
    }

    // ---- Helpers ---------------------------------------------------------

    function _bobDeposits(uint256 amount) internal {
        vm.startPrank(bob);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, bob);
        vm.stopPrank();
    }

    function _aliceOpens() internal {
        vm.prank(alice);
        pool.openVaultPosition();
    }

    function _aliceDepositsCollateral(uint256 amount) internal {
        vm.startPrank(alice);
        amfi.approve(address(adapter), amount);
        pool.depositAsset(address(adapter), abi.encode(amount));
        vm.stopPrank();
    }

    function _aliceBorrows(uint256 amount) internal {
        bytes memory data = abi.encode(uint256(0)); // amount unused for borrow
        vm.prank(alice);
        pool.borrow(address(adapter), data, amount);
    }

    function _aliceRepays(uint256 amount) internal {
        bytes memory data = abi.encode(uint256(0));
        vm.startPrank(alice);
        usdr.approve(address(pool), amount);
        pool.repay(address(adapter), data, amount);
        vm.stopPrank();
    }

    // ---- 1. Lender flow (Bob) --------------------------------------------

    function test_bobDeposit_mintsAgToken1to1() public {
        _bobDeposits(1_000_000e18);
        assertEq(pool.balanceOf(bob), 1_000_000e18, "agTOKEN minted 1:1 at zero util");
        assertEq(usdr.balanceOf(address(pool)), 1_000_000e18, "USDr custody on pool");
        assertEq(pool.totalAssets(), 1_000_000e18);
    }

    function test_bobWithdraw_immediate_returnsAllUsdr() public {
        _bobDeposits(1_000_000e18);
        vm.prank(bob);
        pool.withdraw(1_000_000e18, bob, bob);
        assertEq(usdr.balanceOf(bob), USDR_INITIAL);
        assertEq(pool.balanceOf(bob), 0);
    }

    // ---- 2. Borrower flow (Alice) ----------------------------------------

    function test_aliceFlow_borrow50pctLTV() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18); // 1M AMFI worth ~1M USDr at par
        _aliceBorrows(500_000e18); // 50% LTV

        // Alice receives net = 500k - 50bps = 497.5k
        uint256 fee = (500_000e18 * 50) / 10_000;
        assertEq(usdr.balanceOf(alice), 500_000e18 - fee);
        assertEq(usdr.balanceOf(address(feeSink)), fee, "origination fee routed");

        // Debt minted
        assertEq(debt.balanceOf(alice), 500_000e18);
        assertEq(debt.totalSupply(), 500_000e18);
    }

    function test_borrow_aboveMaxLtv_reverts() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);

        // 71% LTV → above 70% cap → HF < 1 at MAX_LTV
        bytes memory data = abi.encode(uint256(0));
        vm.prank(alice);
        vm.expectRevert(AgamaLendingPool.HealthFactorTooLow.selector);
        pool.borrow(address(adapter), data, 710_000e18);
    }

    function test_borrow_belowMinAmount_reverts() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);

        bytes memory data = abi.encode(uint256(0));
        vm.prank(alice);
        vm.expectRevert(AgamaLendingPool.AmountBelowMinimum.selector);
        pool.borrow(address(adapter), data, 50e18); // below 100e18 min
    }

    // ---- 3. Interest accrual --------------------------------------------

    function test_interestAccrual_30days() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18); // 50% util after this borrow

        uint256 debt0 = debt.balanceOf(alice);
        uint256 share0 = pool.convertToAssets(1e18); // value of 1 agTOKEN

        vm.warp(block.timestamp + 30 days);

        uint256 debt30 = debt.balanceOf(alice);
        uint256 share30 = pool.convertToAssets(1e18);

        // At 50% util with V1 IRM: borrow APR = 7%, lender APR = 7% × 0.5 × 0.9 = 3.15%
        // Over 30 days (linear), borrow growth ≈ 7% × 30/365 ≈ 0.575%
        // Lender growth ≈ 3.15% × 30/365 ≈ 0.259%
        assertGt(debt30, debt0, "debt grew");
        assertGt(share30, share0, "lender share appreciated");
        assertApproxEqRel(debt30, debt0 * 100_575 / 100_000, 0.001e18); // 0.1% tolerance
        assertApproxEqRel(share30, share0 * 100_259 / 100_000, 0.001e18);
    }

    // ---- 4. Repay & exit ------------------------------------------------

    function test_aliceRepayMax_clearsDebt() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        // Mint Alice some extra USDr to cover interest
        vm.prank(admin);
        usdr.mint(alice, 50_000e18);

        vm.warp(block.timestamp + 30 days);

        bytes memory data = abi.encode(uint256(0));
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        pool.repay(address(adapter), data, type(uint256).max);
        vm.stopPrank();

        assertEq(debt.balanceOf(alice), 0, "debt cleared");
    }

    function test_alice_withdrawCollateral_afterFullRepay() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        // mint Alice extra to repay+interest
        vm.prank(admin);
        usdr.mint(alice, 50_000e18);
        vm.warp(block.timestamp + 30 days);

        bytes memory zero = abi.encode(uint256(0));
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        pool.repay(address(adapter), zero, type(uint256).max);
        // now withdraw all collateral
        pool.withdrawAsset(address(adapter), abi.encode(uint256(1_000_000e18)));
        vm.stopPrank();

        assertEq(amfi.balanceOf(alice), AMFI_INITIAL);
    }

    function test_alice_withdrawCollateral_breaksHF_reverts() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18); // 50% LTV — needs collateral ≥ 666k for LLTV 75%

        // Try to pull 500k of collateral → only 500k left, debt ~500k → LTV 100% > LLTV
        bytes memory data = abi.encode(uint256(500_000e18));
        vm.prank(alice);
        vm.expectRevert(AgamaLendingPool.HealthFactorTooLow.selector);
        pool.withdrawAsset(address(adapter), data);
    }

    // ---- 5. Lender exits with yield --------------------------------------

    function test_bobPartialWithdraw_afterAccrual_capturesYield() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18); // pool cash → 500k

        vm.warp(block.timestamp + 30 days);

        // Bob redeems 100k shares — assets returned should exceed 100k due to share appreciation.
        uint256 sharesToRedeem = 100_000e18;
        vm.prank(bob);
        uint256 assetsBack = pool.redeem(sharesToRedeem, bob, bob);

        assertGt(assetsBack, 100_000e18, "share price > 1.0 after accrual");
        // Lender APY at 50% util ≈ 3.15%, over 30 days ≈ 0.259% → expect ~100,259 USDr
        assertApproxEqRel(assetsBack, 100_259e18, 0.005e18);
    }

    function test_bobFullWithdraw_blocksOnLiquidity() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        // Pool has 500k cash, but Bob owns 1M shares. Redeeming all should fail.
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(AgamaLendingPool.LiquidityShortfall.selector);
        pool.redeem(shares, bob, bob);
    }

    function test_bobFullWithdraw_succeedsAfterBorrowerRepays() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        // Mint Alice extra to cover interest, advance time, repay
        vm.prank(admin);
        usdr.mint(alice, 50_000e18);
        vm.warp(block.timestamp + 30 days);
        bytes memory zero = abi.encode(uint256(0));
        vm.startPrank(alice);
        usdr.approve(address(pool), type(uint256).max);
        pool.repay(address(adapter), zero, type(uint256).max);
        vm.stopPrank();

        // Now Bob can redeem all his shares: the pool holds full liquidity + accrued yield.
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        uint256 assetsBack = pool.redeem(shares, bob, bob);

        assertGt(assetsBack, 1_000_000e18, "lender captured yield over the borrowing window");
    }

    // ---- 6. HF view sanity check ----------------------------------------

    function test_healthFactor_view() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        // collateral 1M, LT 80%, debt 500k → HF = 1M × 0.80 / 500k = 1.6
        bytes memory data = abi.encode(uint256(0));
        uint256 hf = pool.calculateHealthFactor(address(adapter), alice, data);
        assertApproxEqRel(hf, 1.6e27, 0.01e18);
    }

    function test_healthFactor_zeroDebt_max() public {
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        bytes memory data = abi.encode(uint256(0));
        uint256 hf = pool.calculateHealthFactor(address(adapter), alice, data);
        assertEq(hf, type(uint256).max);
    }

    // ---- 7. Vault opening guards ----------------------------------------

    function test_depositAsset_withoutVault_reverts() public {
        vm.startPrank(alice);
        amfi.approve(address(adapter), 1e18);
        vm.expectRevert(AgamaLendingPool.VaultPositionNotOpened.selector);
        pool.depositAsset(address(adapter), abi.encode(uint256(1e18)));
        vm.stopPrank();
    }

    function test_openVault_twice_reverts() public {
        _aliceOpens();
        vm.prank(alice);
        vm.expectRevert(AgamaLendingPool.VaultPositionAlreadyOpened.selector);
        pool.openVaultPosition();
    }

    // ---- 8. Testnet-mode gating -----------------------------------------

    function test_testnetMode_setOnConstruction() public view {
        assertTrue(pool.testnetMode(), "testnet pool wired in testnet mode");
    }

    function test_fastForwardInterest_mainnet_reverts() public {
        AgamaLendingPool mainnet = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Mainnet", "agMAIN", IRM.defaults(), false
        );
        vm.prank(admin);
        vm.expectRevert(AgamaLendingPool.OnlyTestnet.selector);
        mainnet.fastForwardInterest(365 days);
    }

    function test_fastForwardInterest_testnetMode_growsIndices() public {
        _bobDeposits(1_000_000e18);
        _aliceOpens();
        _aliceDepositsCollateral(1_000_000e18);
        _aliceBorrows(500_000e18);

        uint256 borrowIdx0 = pool.getNormalizedDebt();
        // Simulate one year of accrual instantly
        vm.prank(admin);
        pool.fastForwardInterest(365 days);
        uint256 borrowIdx1 = pool.getNormalizedDebt();

        // At 50% util borrow APR is 7%, so index should bump ~7%
        assertGt(borrowIdx1, borrowIdx0);
        assertApproxEqRel(borrowIdx1, borrowIdx0 * 107 / 100, 0.01e18);
    }

    // ---- 9. Production parameters round-trip ----------------------------

    function test_productionParams_consistent() public view {
        // Pool params (identical mainnet/testnet)
        assertEq(pool.reserveFactorBps(), 1000);
        assertEq(pool.originationFeeBps(), 50);
        assertEq(pool.depositFeeBps(), 0);
        assertEq(pool.vaultOpeningFee(), 0);
        // IRM
        IRM.Params memory p = pool.getIRMParams();
        assertEq(p.baseRate, 0.02e27);
        assertEq(p.slope1, 0.08e27);
        assertEq(p.slope2, 0.6e27);
        assertEq(p.optimalUtil, 0.8e27);
        // Adapter risk
        assertEq(adapter.MAX_LTV(), 7000);
        assertEq(adapter.LIQUIDATION_THRESHOLD(), 8000);
        assertEq(adapter.LIQUIDATION_BONUS(), 500);
        assertEq(adapter.ORACLE_STALENESS_MAX(), 24 hours);
    }
}

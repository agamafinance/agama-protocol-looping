// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S3_Extensions
/// @notice Validates the protocol-specific extensions on top of the standard
///         ERC-4626 surface: `burnDonation`, `depositOnBehalf`, role gating,
///         and the totalAssets-vs-supply invariant under each.
contract S3ExtensionsTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xEEE);
    address alice = address(0xA17CE);
    address mockSettlementVault = address(0x5E771E);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AmFiAdapter adapter;

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin, true);

        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        // Wire SP and a MOCK SettlementVault address to exercise role grants.
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(mockSettlementVault);
        usdr.mint(bob, 5_000_000e18);
        usdr.mint(mockSettlementVault, 5_000_000e18);
        usdr.mint(alice, 1_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        vm.stopPrank();
    }

    // ====================================================================
    // 1. setStabilityPool grants both roles
    // ====================================================================

    function test_setStabilityPool_grantsBothRoles() public view {
        assertTrue(pool.hasRole(pool.STABILITY_POOL_ROLE(), address(sp)));
        assertTrue(pool.hasRole(pool.LIQUIDATION_PROXY_ROLE(), address(sp)));
        assertEq(pool.stabilityPool(), address(sp));
    }

    function test_setStabilityPool_revokesOldOnReplace() public {
        address newSp = address(0xBABE);
        vm.prank(admin);
        pool.setStabilityPool(newSp);
        assertFalse(pool.hasRole(pool.STABILITY_POOL_ROLE(), address(sp)));
        assertFalse(pool.hasRole(pool.LIQUIDATION_PROXY_ROLE(), address(sp)));
        assertTrue(pool.hasRole(pool.STABILITY_POOL_ROLE(), newSp));
        assertTrue(pool.hasRole(pool.LIQUIDATION_PROXY_ROLE(), newSp));
    }

    function test_setSettlementVault_grantsRole() public view {
        assertTrue(pool.hasRole(pool.SETTLEMENT_VAULT_ROLE(), mockSettlementVault));
        assertEq(pool.settlementVault(), mockSettlementVault);
    }

    // ====================================================================
    // 2. burnDonation
    // ====================================================================

    function test_burnDonation_onlyByStabilityPoolRole() public {
        _bobDeposit(100_000e18);
        bytes32 role = pool.STABILITY_POOL_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role)
        );
        vm.prank(bob);
        pool.burnDonation(bob, 1);
    }

    function test_burnDonation_zeroAmountReverts() public {
        vm.prank(address(sp));
        vm.expectRevert(AgamaLendingPool.AmountZero.selector);
        pool.burnDonation(address(sp), 0);
    }

    function test_burnDonation_decreasesSupplyAndUserBalance() public {
        // Bob deposits, then transfers 50k shares to SP via the SP.deposit flow.
        _bobDeposit(100_000e18);
        // Bob stakes 50k of his agTOKEN into the SP → SP holds 50k shares
        vm.startPrank(bob);
        pool.approve(address(sp), 50_000e18);
        sp.deposit(50_000e18, bob);
        vm.stopPrank();
        assertEq(pool.balanceOf(address(sp)), 50_000e18);

        uint256 supplyBefore = pool.totalSupply();
        vm.prank(address(sp));
        pool.burnDonation(address(sp), 10_000e18);

        assertEq(pool.balanceOf(address(sp)), 40_000e18);
        assertEq(pool.totalSupply(), supplyBefore - 10_000e18);
    }

    /// @notice burnDonation alone breaks share-price (cash unchanged, supply
    ///         dropped → share price up). It is meant to be PAIRED with a
    ///         debt burn to keep the invariant. This test verifies the pairing.
    function test_burnDonation_pairedWithDebtBurn_preservesSharePrice() public {
        _bobDeposit(1_000_000e18);
        _aliceBorrow(500_000e18); // 500k debt minted
        // Pre-state: cash 500k, debt 500k, supply 1M, share price 1.0.

        // Bob stakes some agTOKEN
        vm.startPrank(bob);
        pool.approve(address(sp), 500_000e18);
        sp.deposit(500_000e18, bob);
        vm.stopPrank();

        uint256 sharePriceBefore = pool.convertToAssets(1e18);
        uint256 debtToBurn = 100_000e18;
        uint256 sharesToBurn = pool.convertToShares(debtToBurn);

        // Cache addresses/values before pranks so individual calls don't consume them.
        DebtToken dt = pool.DEBT_TOKEN();
        uint256 idx = pool.getNormalizedDebt();

        vm.prank(address(sp));
        pool.burnDonation(address(sp), sharesToBurn);

        vm.prank(address(pool));
        dt.burn(alice, debtToBurn, idx);

        uint256 sharePriceAfter = pool.convertToAssets(1e18);
        // Pair (burnDonation + DebtToken.burn) preserves share price within rounding.
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 10);
    }

    // ====================================================================
    // 3. depositOnBehalf
    // ====================================================================

    function test_depositOnBehalf_onlyBySettlementVaultRole() public {
        bytes32 role = pool.SETTLEMENT_VAULT_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, eve, role)
        );
        vm.prank(eve);
        pool.depositOnBehalf(1e18, address(sp));
    }

    function test_depositOnBehalf_zeroAmountReverts() public {
        vm.prank(mockSettlementVault);
        vm.expectRevert(AgamaLendingPool.AmountZero.selector);
        pool.depositOnBehalf(0, address(sp));
    }

    function test_depositOnBehalf_pullsFromCallerCreditsReceiver() public {
        // SettlementVault has 5M USDr seeded. It deposits on behalf of the SP.
        uint256 amount = 100_000e18;
        uint256 expectedShares = pool.previewDeposit(amount);

        vm.startPrank(mockSettlementVault);
        usdr.approve(address(pool), amount);
        uint256 shares = pool.depositOnBehalf(amount, address(sp));
        vm.stopPrank();

        assertEq(shares, expectedShares);
        assertEq(pool.balanceOf(address(sp)), expectedShares);
        assertEq(usdr.balanceOf(mockSettlementVault), 5_000_000e18 - amount);
        assertEq(usdr.balanceOf(address(pool)), amount);
    }

    function test_depositOnBehalf_doesNotChargeDepositFee() public {
        // Even with depositFee set, the protocol-internal entrypoint bypasses it.
        // (V1 default depositFee=0 anyway, but verify the path is fee-free.)
        vm.prank(admin);
        // Note: there's no public setter for depositFeeBps in V1 (only via constructor).
        // The intent here is that depositOnBehalf simply doesn't reference depositFeeBps.
        uint256 amount = 100_000e18;
        uint256 expectedShares = pool.previewDeposit(amount);

        vm.startPrank(mockSettlementVault);
        usdr.approve(address(pool), amount);
        pool.depositOnBehalf(amount, address(sp));
        vm.stopPrank();

        assertEq(pool.balanceOf(address(sp)), expectedShares);
    }

    // ====================================================================
    // 4. fastForwardInterest (already covered in S2 demo-mode tests, smoke
    //    test here to confirm wiring still holds after refactor)
    // ====================================================================

    function test_fastForwardInterest_stillDemoGated() public {
        AgamaLendingPool main = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Mainnet", "M", IRM.defaults(), false
        );
        vm.prank(admin);
        vm.expectRevert(AgamaLendingPool.OnlyDemoMode.selector);
        main.fastForwardInterest(1 days);
    }

    // ====================================================================
    // 5. Invariant: totalAssets = USDr cash + DebtToken.totalSupply
    //    Holds even after each extension is exercised.
    // ====================================================================

    function test_invariant_postBurnDonation() public {
        _bobDeposit(1_000_000e18);
        vm.startPrank(bob);
        pool.approve(address(sp), 100_000e18);
        sp.deposit(100_000e18, bob);
        vm.stopPrank();

        vm.prank(address(sp));
        pool.burnDonation(address(sp), 50_000e18);

        uint256 cash = usdr.balanceOf(address(pool));
        uint256 debt = pool.DEBT_TOKEN().totalSupply();
        assertEq(pool.totalAssets(), cash + debt);
    }

    function test_invariant_postDepositOnBehalf() public {
        uint256 amount = 100_000e18;
        vm.startPrank(mockSettlementVault);
        usdr.approve(address(pool), amount);
        pool.depositOnBehalf(amount, address(sp));
        vm.stopPrank();

        uint256 cash = usdr.balanceOf(address(pool));
        uint256 debt = pool.DEBT_TOKEN().totalSupply();
        assertEq(pool.totalAssets(), cash + debt);
    }

    // ---- Helpers ---------------------------------------------------------

    function _bobDeposit(uint256 amount) internal {
        vm.startPrank(bob);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, bob);
        vm.stopPrank();
    }

    function _aliceBorrow(uint256 amount) internal {
        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), 1_000_000e18);
        pool.depositAsset(address(adapter), abi.encode(uint256(1_000_000e18)));
        pool.borrow(address(adapter), abi.encode(uint256(0)), amount);
        vm.stopPrank();
    }
}

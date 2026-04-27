// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S3_ERC4626Compliance
/// @notice Verifies that the LendingPool exposes the standard ERC-4626 surface
///         exactly as expected, even after protocol-specific extensions
///         (`burnDonation`, `depositOnBehalf`, finalizeLiquidation) have been
///         added to the contract. Any external integrator (aggregator, wallet,
///         vault wrapper) should be able to interact with agTOKEN through the
///         vanilla 4626 interface without surprises.
contract S3ERC4626ComplianceTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AmFiAdapter adapter;

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);

        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        usdr.mint(bob, 10_000_000e18);
        usdr.mint(alice, 1_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        vm.stopPrank();
    }

    // ====================================================================
    // 1. Identity invariant
    //
    //   At the genesis ratio (totalSupply == 0), 1 USDr == 1e6 shares due
    //   to the _decimalsOffset = 6 inflation-attack mitigation.
    // ====================================================================

    uint256 internal constant SHARE_OFFSET = 1e6;

    function test_genesis_oneAssetIsOneShare() public view {
        assertEq(pool.convertToShares(1e18), 1e18 * SHARE_OFFSET);
        assertEq(pool.convertToAssets(1e18 * SHARE_OFFSET), 1e18);
    }

    // ====================================================================
    // 2. asset() / decimals() / underlying metadata
    // ====================================================================

    function test_asset_returnsUSDr() public view {
        assertEq(pool.asset(), address(usdr));
    }

    function test_decimals_matchesUnderlying() public view {
        // OZ ERC4626 with _decimalsOffset = 6 returns asset.decimals() + 6.
        assertEq(pool.decimals(), usdr.decimals() + 6);
    }

    // ====================================================================
    // 3. preview-then-execute symmetry
    //
    //   The amount returned by `previewDeposit/previewMint/previewWithdraw/
    //   previewRedeem` must equal what `deposit/mint/withdraw/redeem`
    //   actually return.
    // ====================================================================

    function test_previewDeposit_matchesDeposit() public {
        uint256 assets = 500_000e18;
        uint256 expectedShares = pool.previewDeposit(assets);

        vm.startPrank(bob);
        usdr.approve(address(pool), assets);
        uint256 actualShares = pool.deposit(assets, bob);
        vm.stopPrank();

        assertEq(actualShares, expectedShares);
    }

    function test_previewMint_matchesMint() public {
        uint256 shares = 250_000e18;
        uint256 expectedAssets = pool.previewMint(shares);

        vm.startPrank(bob);
        usdr.approve(address(pool), expectedAssets);
        uint256 actualAssets = pool.mint(shares, bob);
        vm.stopPrank();

        assertEq(actualAssets, expectedAssets);
    }

    function test_previewWithdraw_matchesWithdraw() public {
        _bobDeposit(500_000e18);
        uint256 assets = 100_000e18;
        uint256 expectedShares = pool.previewWithdraw(assets);

        vm.prank(bob);
        uint256 actualShares = pool.withdraw(assets, bob, bob);
        assertEq(actualShares, expectedShares);
    }

    function test_previewRedeem_matchesRedeem() public {
        _bobDeposit(500_000e18);
        uint256 shares = 100_000e18;
        uint256 expectedAssets = pool.previewRedeem(shares);

        vm.prank(bob);
        uint256 actualAssets = pool.redeem(shares, bob, bob);
        assertEq(actualAssets, expectedAssets);
    }

    // ====================================================================
    // 4. convertToShares ∘ convertToAssets identity (within 1 wei)
    // ====================================================================

    function testFuzz_convert_roundtrip_assetsToSharesToAssets(uint128 amountSeed) public {
        _bobDeposit(1_000_000e18);
        // Make the share price non-trivial so we exercise the math.
        _aliceBorrow(500_000e18);
        vm.warp(block.timestamp + 30 days);

        uint256 assets = bound(uint256(amountSeed), 1e18, 100_000e18);
        uint256 shares = pool.convertToShares(assets);
        uint256 back = pool.convertToAssets(shares);
        // Round-trip rounding: OZ ERC4626 uses FLOOR on each direction. With
        // _decimalsOffset = 6 the share unit is 1e6 finer than the asset
        // unit, so rounding loss in the assets-shares-assets direction stays
        // within 1 wei.
        if (back > assets) {
            assertLe(back - assets, 1);
        } else {
            assertLe(assets - back, 1);
        }
    }

    function testFuzz_convert_roundtrip_sharesToAssetsToShares(uint128 sharesSeed) public {
        _bobDeposit(1_000_000e18);
        _aliceBorrow(500_000e18);
        vm.warp(block.timestamp + 30 days);

        // With _decimalsOffset = 6, the shares-assets-shares roundtrip can
        // lose up to (totalSupply / totalAssets) wei per direction =
        // ~SHARE_OFFSET wei. Use a tolerance of 2 * SHARE_OFFSET for safety.
        uint256 shares = bound(uint256(sharesSeed), 1e18 * SHARE_OFFSET, 100_000e18 * SHARE_OFFSET);
        uint256 assets = pool.convertToAssets(shares);
        uint256 back = pool.convertToShares(assets);
        if (back > shares) {
            assertLe(back - shares, 2 * SHARE_OFFSET);
        } else {
            assertLe(shares - back, 2 * SHARE_OFFSET);
        }
    }

    // ====================================================================
    // 5. totalAssets invariant: cash + DebtToken.totalSupply
    // ====================================================================

    function test_totalAssets_emptyPool_isZero() public view {
        assertEq(pool.totalAssets(), 0);
    }

    function test_totalAssets_postDeposit_isCash() public {
        _bobDeposit(500_000e18);
        assertEq(pool.totalAssets(), 500_000e18);
        assertEq(usdr.balanceOf(address(pool)), 500_000e18);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);
    }

    function test_totalAssets_postBorrow_isCashPlusDebt() public {
        _bobDeposit(1_000_000e18);
        _aliceBorrow(500_000e18);
        // pool cash = 1M - 500k = 500k; debt total = 500k → totalAssets = 1M.
        assertEq(pool.totalAssets(), 1_000_000e18);
    }

    function test_totalAssets_invariantAfter30Days() public {
        _bobDeposit(1_000_000e18);
        _aliceBorrow(500_000e18);
        vm.warp(block.timestamp + 30 days);

        uint256 cash = usdr.balanceOf(address(pool));
        uint256 debt = pool.DEBT_TOKEN().totalSupply();
        assertEq(pool.totalAssets(), cash + debt, "invariant: totalAssets = cash + debt");
    }

    // ====================================================================
    // 6. Sum of balances == totalSupply (vanilla ERC20 invariant)
    // ====================================================================

    function test_balanceSum_equalsTotalSupply() public {
        _bobDeposit(500_000e18);
        vm.startPrank(alice);
        usdr.approve(address(pool), 200_000e18);
        pool.deposit(200_000e18, alice);
        vm.stopPrank();

        assertEq(pool.balanceOf(bob) + pool.balanceOf(alice), pool.totalSupply());
    }

    // ====================================================================
    // 7. EIP-4626 events (Deposit / Withdraw)
    // ====================================================================

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function test_deposit_emitsERC4626DepositEvent() public {
        uint256 assets = 100_000e18;
        uint256 expectedShares = pool.previewDeposit(assets);
        vm.startPrank(bob);
        usdr.approve(address(pool), assets);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Deposit(bob, bob, assets, expectedShares);
        pool.deposit(assets, bob);
        vm.stopPrank();
    }

    function test_withdraw_emitsERC4626WithdrawEvent() public {
        _bobDeposit(500_000e18);
        uint256 assets = 50_000e18;
        uint256 expectedShares = pool.previewWithdraw(assets);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Withdraw(bob, bob, bob, assets, expectedShares);
        vm.prank(bob);
        pool.withdraw(assets, bob, bob);
    }

    // ====================================================================
    // 8. maxX limits
    // ====================================================================

    function test_maxDeposit_unlimitedByDefault() public view {
        // V1 default supplyCap is type(uint256).max → maxDeposit = max.
        assertEq(pool.maxDeposit(bob), type(uint256).max);
    }

    function test_maxWithdraw_capsAtUserBalance() public {
        _bobDeposit(500_000e18);
        assertEq(pool.maxWithdraw(bob), 500_000e18);
    }

    function test_maxRedeem_capsAtUserShares() public {
        _bobDeposit(500_000e18);
        assertEq(pool.maxRedeem(bob), 500_000e18 * SHARE_OFFSET);
    }

    // ====================================================================
    // 9. External integration smoke test
    //   A third-party contract (here: a barebones wrapper) deposits into the
    //   pool and reads back via standard ERC4626 functions. Exercises the
    //   invariant that the protocol extensions don't disturb the standard
    //   surface.
    // ====================================================================

    function test_externalIntegrator_canRoundtrip() public {
        ExternalIntegrator wrapper = new ExternalIntegrator(IERC4626(address(pool)));

        vm.prank(admin);
        usdr.mint(address(wrapper), 100_000e18);

        wrapper.depositAll();
        assertEq(pool.balanceOf(address(wrapper)), 100_000e18 * SHARE_OFFSET);

        wrapper.redeemAll();
        assertEq(usdr.balanceOf(address(wrapper)), 100_000e18);
        assertEq(pool.balanceOf(address(wrapper)), 0);
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

/// @dev Minimal third-party "integrator" — uses ONLY the standard ERC-4626
///      surface to interact with the vault.
contract ExternalIntegrator {
    IERC4626 public immutable VAULT;
    IERC20 public immutable ASSET;

    constructor(IERC4626 vault) {
        VAULT = vault;
        ASSET = IERC20(vault.asset());
    }

    function depositAll() external {
        uint256 bal = ASSET.balanceOf(address(this));
        ASSET.approve(address(VAULT), bal);
        VAULT.deposit(bal, address(this));
    }

    function redeemAll() external {
        uint256 shares = IERC20(address(VAULT)).balanceOf(address(this));
        VAULT.redeem(shares, address(this), address(this));
    }
}

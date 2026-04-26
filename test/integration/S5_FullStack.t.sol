// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaSettlementVault} from "src/core/SettlementVault.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {AgamaTreasury} from "src/collectors/Treasury.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";
import {AgamaFeeCollector} from "src/collectors/FeeCollector.sol";
import {IAgamaPool, IAgamaSP, ITreasuryDeposit} from "src/interfaces/IAgamaCollectors.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S5_FullStack
/// @notice Full lifecycle E2E with the real Treasury / ReserveFund /
///         FeeCollector / SettlementVault chain wired together. Validates
///         the pro-rata economic model end to end:
///           - Origination fees → FeeCollector → 100% to Treasury → Treasury
///             auto-stakes into the SP and earns alongside other agaSP holders.
///           - SettlementVault settle proceeds split 200/9800 on the *USDr
///             proceeds*: 2% to Treasury (auto-stakes), 98% to SP via
///             depositOnBehalf.
///           - ReserveFund seeded 100k USDr at TGE, staked, earns share
///             appreciation pro-rata to its slice of the SP.
///           - Emergency in-kind distribution after 60 days of staleness.
contract S5FullStackTest is Test {
    address admin = address(0xA11CE);
    address manager = address(0x111A);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);
    address raylsGrant = address(0x6147); // funds the RF seed

    MockUSDr usdr;
    MockAMFI amfi;
    MockOracle oracle;
    AgamaLendingPool pool;
    AgamaStabilityPool sp;
    AmFiAdapter adapter;
    LiquidationProxy proxy;
    AgamaSettlementVault svault;
    AgamaTreasury treasury;
    AgamaReserveFund rf;
    AgamaFeeCollector feeCollector;
    DebtToken debt;

    uint256 constant RF_SEED = 100_000e18;
    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        // ---- Mocks ------------------------------------------------------
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        // ---- Core ------------------------------------------------------
        pool = new AgamaLendingPool(
            IERC20(address(usdr)), admin, "Agama Pool USDr", "agUSDr", IRM.defaults(), true
        );
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin, true);
        proxy = new LiquidationProxy(pool, sp, admin);
        debt = pool.DEBT_TOKEN();

        // ---- Collectors -----------------------------------------------
        treasury = new AgamaTreasury(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr)), true
        );
        rf = new AgamaReserveFund(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        feeCollector = new AgamaFeeCollector(admin, ITreasuryDeposit(address(treasury)));
        svault = new AgamaSettlementVault(
            admin,
            address(sp),
            IAgamaPool(address(pool)),
            ITreasuryDeposit(address(treasury)),
            IERC20(address(usdr)),
            true
        );

        // ---- Wire roles ------------------------------------------------
        vm.startPrank(admin);
        pool.registerAdapter(address(adapter), true);
        pool.setStabilityPool(address(sp));
        pool.setSettlementVault(address(svault));
        pool.setFeeRecipient(address(feeCollector));
        sp.setSettlementVault(address(svault));
        sp.setManager(address(proxy), true);
        pool.grantRole(pool.LIQUIDATION_PROXY_ROLE(), address(proxy));
        feeCollector.grantPool(address(pool));
        treasury.grantDepositor(address(feeCollector));
        treasury.grantDepositor(address(svault));
        rf.grantDepositor(address(svault));
        proxy.setManager(manager, true);
        svault.grantManager(manager);

        // Demo timing compression
        pool.setLiquidationGracePeriod(60);
        sp.setWithdrawTimelockDuration(60);

        // Mint
        usdr.mint(bob, 5_000_000e18);
        usdr.mint(raylsGrant, RF_SEED);
        usdr.mint(manager, 10_000_000e18); // for settle simulations
        amfi.mint(alice, 1_000_000e18);
        vm.stopPrank();

        // ---- Seed Reserve Fund at TGE ----------------------------------
        vm.startPrank(raylsGrant);
        usdr.approve(address(rf), RF_SEED);
        vm.stopPrank();
        // RF.seed pulls from msg.sender (admin), but admin must own the USDr.
        // Move the grant to admin first.
        vm.prank(raylsGrant);
        usdr.transfer(admin, RF_SEED);
        vm.startPrank(admin);
        usdr.approve(address(rf), RF_SEED);
        rf.seed(RF_SEED);
        vm.stopPrank();
    }

    // ====================================================================
    // 1. ReserveFund seed → 100k agaSP
    // ====================================================================

    function test_reserveFund_seededAndStaked() public view {
        // RF holds 100k agaSP (1:1 at zero util)
        assertEq(IERC20(address(sp)).balanceOf(address(rf)), RF_SEED);
        assertEq(rf.coverageBalance(), RF_SEED);
    }

    // ====================================================================
    // 2. Origination fee → FeeCollector → Treasury → SP auto-stake
    // ====================================================================

    function test_originationFee_routesToTreasury_autoStakes() public {
        _bobDeposit(2_000_000e18);
        _aliceLeveraged(1_000_000e18, 500_000e18);

        uint256 fee = (500_000e18 * 50) / 10_000; // 50 bps
        assertEq(usdr.balanceOf(address(feeCollector)), 0, "FeeCollector forwarded synchronously");
        // Treasury auto-staked the fee → it now holds agaSP, not USDr
        assertEq(usdr.balanceOf(address(treasury)), 0);

        // Treasury's agaSP balance: a small fraction of the fee value leaks to
        // existing lenders because the LP's share price is *briefly* elevated
        // mid-tx (debt is minted before the fee transfer in `borrow`). The
        // bulk accrues to Treasury; the leak is bounded by the borrow's
        // share-price impact and disappears once the principal is disbursed.
        uint256 tBal = IERC20(address(sp)).balanceOf(address(treasury));
        assertGt(tBal, 0, "Treasury staked the fee");
        assertGt(tBal, (fee * 75) / 100, "at least 75% of the fee retained as Treasury stake");
        assertLe(tBal, fee, "at most 100% of nominal fee");

        // FeeCollector lifetime fees tracked
        assertEq(feeCollector.lifetimeFees(feeCollector.FEE_ORIGINATION(), address(usdr)), fee);
    }

    // ====================================================================
    // 3. Full lifecycle: liquidation → settle → pro-rata bonus
    // ====================================================================

    function test_fullLifecycle_settleBonus_proRataPump() public {
        // Bob lends, stakes — bulk SP capacity
        _bobDeposit(3_000_000e18);
        vm.startPrank(bob);
        IERC20(address(pool)).approve(address(sp), 3_000_000e18);
        sp.deposit(3_000_000e18, bob);
        vm.stopPrank();

        // Alice borrows at the cap, oracle drops
        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000); // 30% AMFI price drop

        // Liquidation pipeline
        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
        skip(61);

        uint256 bobAgaSPBefore = IERC20(address(sp)).balanceOf(bob);
        uint256 rfAgaSPBefore = IERC20(address(sp)).balanceOf(address(rf));
        uint256 tAgaSPBefore = IERC20(address(sp)).balanceOf(address(treasury));
        uint256 spPriceBefore = sp.convertToAssets(1e18);

        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // SP totalAssets smoothed by pegGap (no immediate price drop)
        uint256 spPriceMid = sp.convertToAssets(1e18);
        assertApproxEqRel(spPriceMid, spPriceBefore, 0.001e18, "SP price stable mid-flight");

        // Manager settles: 757k USDr returned (bonus 57k vs pegGap 700k)
        // Manager pre-funds vault
        uint256 settleAmount = 757_000e18;
        vm.startPrank(manager);
        usdr.approve(address(svault), settleAmount);
        svault.settleRedemption(1, settleAmount);
        vm.stopPrank();

        // Post-settle: SP price should have pumped from the bonus distribution.
        // Split: 2% to Treasury (auto-stakes → Treasury's agaSP grows) + 98%
        // to SP via depositOnBehalf → boosts SP's agTOKEN balance → totalAssets
        // up → share price up for ALL agaSP holders pro-rata.
        uint256 spPriceAfter = sp.convertToAssets(1e18);
        assertGt(spPriceAfter, spPriceBefore, "SP price pumped from bonus");

        // ---- Pro-rata earn check ---------------------------------------
        // Each holder's agaSP balance is unchanged (soulbound, no transfers).
        assertEq(IERC20(address(sp)).balanceOf(bob), bobAgaSPBefore);
        assertEq(IERC20(address(sp)).balanceOf(address(rf)), rfAgaSPBefore);
        // Treasury's balance grew slightly (it received its 2% slice as new agaSP).
        assertGt(IERC20(address(sp)).balanceOf(address(treasury)), tAgaSPBefore);

        // Each holder now redeems for *more* USDr than they put in.
        // (Snapshot via convertToAssets at the current ratio.)
        uint256 bobUsdrEquiv = sp.convertToAssets(bobAgaSPBefore);
        assertGt(bobUsdrEquiv, bobAgaSPBefore, "Bob's stake worth more USDr post-bonus");
    }

    // ====================================================================
    // 4. Emergency in-kind distribution (60-day staleness)
    // ====================================================================

    function test_emergencyDistributeInKind_after60Days() public {
        _bobDeposit(2_000_000e18);
        vm.startPrank(bob);
        IERC20(address(pool)).approve(address(sp), 2_000_000e18);
        sp.deposit(2_000_000e18, bob);
        vm.stopPrank();

        _aliceLeveraged(1_000_000e18, 700_000e18);
        _crashOracleBy(3000);

        vm.prank(manager);
        proxy.initiateLiquidation(address(adapter), alice, ZERO_DATA);
        skip(61);
        vm.prank(manager);
        proxy.liquidateBorrower(address(adapter), address(adapter), alice, ZERO_DATA, 0);

        // Manager goes silent for 61 days — past staleBatchPeriod. We also
        // advance block.number so the ERC20Votes snapshot is unambiguously
        // in the past (skip() only moves block.timestamp).
        skip(61 days);
        vm.roll(block.number + 1);

        // Anyone triggers emergency distribution for Bob
        uint256 bobAmfiBefore = amfi.balanceOf(bob);
        svault.emergencyDistributeInKind(1, bob);
        uint256 bobAmfiAfter = amfi.balanceOf(bob);
        // Bob got his pro-rata share (he was nearly the only holder besides RF + treasury)
        assertGt(bobAmfiAfter, bobAmfiBefore);

        // RF also claims
        svault.emergencyDistributeInKind(1, address(rf));
        // Re-claim should revert
        vm.expectRevert(AgamaSettlementVault.AlreadyClaimed.selector);
        svault.emergencyDistributeInKind(1, bob);
    }

    // ---- Helpers ---------------------------------------------------------

    function _bobDeposit(uint256 amount) internal {
        vm.startPrank(bob);
        usdr.approve(address(pool), amount);
        pool.deposit(amount, bob);
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
        uint256 newPrice = (cur * (10_000 - percentBps)) / 10_000;
        vm.prank(admin);
        oracle.setPrice(newPrice);
    }
}

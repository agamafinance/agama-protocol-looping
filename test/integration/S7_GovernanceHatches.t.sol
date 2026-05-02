// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgamaLendingPool} from "src/core/LendingPool.sol";
import {AgamaStabilityPool} from "src/core/StabilityPool.sol";
import {AgamaSettlementVault} from "src/core/SettlementVault.sol";
import {LiquidationProxy} from "src/core/LiquidationProxy.sol";
import {AmFiAdapter} from "src/adapters/AmFiAdapter.sol";
import {AgamaTreasury} from "src/collectors/Treasury.sol";
import {AgamaReserveFund} from "src/collectors/ReserveFund.sol";
import {AgamaFeeCollector} from "src/collectors/FeeCollector.sol";
import {IAgamaPool, IAgamaSP, ITreasuryDeposit} from "src/interfaces/IAgamaCollectors.sol";
import {MockUSDr} from "src/mocks/MockUSDr.sol";
import {MockAMFI} from "src/mocks/MockAMFI.sol";
import {MockOracle} from "src/mocks/MockOracle.sol";
import {InterestRateModel as IRM} from "src/libs/InterestRateModel.sol";

/// @title S7_GovernanceHatches
/// @notice Verifies the V1 governance escape hatches added to replace the
///         heavy timing rails (no more grace, no more SP timelock):
///           1. `replaceManager(old, new)` for hot-swapping a compromised
///              or inactive keeper without downtime.
///           2. `forceEmergencySettlement(batchId)` for governance to
///              unlock per-holder in-kind claims before the 60-day stale
///              window.
contract S7GovernanceHatchesTest is Test {
    address admin = address(0xA11CE);
    address oldManager = address(0x111A);
    address newManager = address(0x222B);
    address bob = address(0xB0B);
    address alice = address(0xA17CE);

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

    bytes constant ZERO_DATA = abi.encode(uint256(0));

    function setUp() public {
        usdr = new MockUSDr(admin);
        amfi = new MockAMFI(admin, 0.16e27);
        oracle = new MockOracle(admin, 1e18);

        pool =
            new AgamaLendingPool(IERC20(address(usdr)), admin, "Agama Yield", "agYLD", IRM.defaults(), true);
        adapter = new AmFiAdapter(address(pool), amfi, oracle, admin, 7000, 8000, 500, 24 hours);
        sp = new AgamaStabilityPool(IERC20(address(pool)), admin);
        proxy = new LiquidationProxy(pool, sp, admin);
        treasury =
            new AgamaTreasury(admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr)));
        rf = new AgamaReserveFund(
            admin, IAgamaPool(address(pool)), IAgamaSP(address(sp)), IERC20(address(usdr))
        );
        feeCollector = new AgamaFeeCollector(admin, ITreasuryDeposit(address(treasury)));
        svault = new AgamaSettlementVault(
            admin,
            address(sp),
            IAgamaPool(address(pool)),
            ITreasuryDeposit(address(treasury)),
            IERC20(address(usdr))
        );

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
        proxy.setManager(oldManager, true);
        svault.grantManager(oldManager);

        usdr.mint(admin, 100_000e18);
        usdr.approve(address(rf), 100_000e18);
        rf.seed(100_000e18);

        usdr.mint(bob, 5_000_000e18);
        amfi.mint(alice, 1_000_000e18);
        vm.stopPrank();
    }

    // ---- 1. replaceManager hot-swap ----------------------------------

    function test_replaceManager_swapsRoleAtomically() public {
        bytes32 role = svault.MANAGER_ROLE();
        assertTrue(svault.hasRole(role, oldManager));
        assertFalse(svault.hasRole(role, newManager));

        vm.prank(admin);
        svault.replaceManager(oldManager, newManager);

        assertFalse(svault.hasRole(role, oldManager), "old revoked");
        assertTrue(svault.hasRole(role, newManager), "new granted");
    }

    function test_replaceManager_unauthorized_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        svault.replaceManager(oldManager, newManager);
    }

    // ---- Phase B: replaceManager input validation -------------------

    function test_replaceManager_zeroOld_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidManager.selector);
        svault.replaceManager(address(0), newManager);
    }

    function test_replaceManager_zeroNew_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidManager.selector);
        svault.replaceManager(oldManager, address(0));
    }

    function test_replaceManager_sameAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidManager.selector);
        svault.replaceManager(oldManager, oldManager);
    }

    function test_replaceManager_oldNotManager_reverts() public {
        // bob never had MANAGER_ROLE
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidManager.selector);
        svault.replaceManager(bob, newManager);
    }

    // ---- Phase B: setStaleBatchPeriod bounds ------------------------

    function test_setStaleBatchPeriod_belowMin_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidPeriod.selector);
        svault.setStaleBatchPeriod(1 hours); // below 1 day floor
    }

    function test_setStaleBatchPeriod_aboveMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidPeriod.selector);
        svault.setStaleBatchPeriod(366 days); // above 365 day ceiling
    }

    // ---- Phase B: setSplit redeemBps floor --------------------------

    function test_setSplit_redeemBpsBelowFloor_reverts() public {
        AgamaSettlementVault.LiquidationSplit memory bad =
            AgamaSettlementVault.LiquidationSplit({treasuryBps: 6_000, redeemBps: 4_000});
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.InvalidSplit.selector);
        svault.setSplit(bad);
    }

    function test_setSplit_redeemBpsAtFloor_works() public {
        AgamaSettlementVault.LiquidationSplit memory ok =
            AgamaSettlementVault.LiquidationSplit({treasuryBps: 5_000, redeemBps: 5_000});
        vm.prank(admin);
        svault.setSplit(ok);
        // No revert means it passed.
    }

    // ---- Phase C: sweepDust -----------------------------------------

    function test_sweepDust_transfersResidualToRecipient() public {
        // Send stuck USDr to the vault directly.
        uint256 stuck = 123e18;
        vm.startPrank(admin);
        usdr.mint(admin, stuck);
        usdr.transfer(address(svault), stuck);
        vm.stopPrank();

        address recipient = address(0xCAFE);
        uint256 before_ = usdr.balanceOf(recipient);

        vm.prank(admin);
        uint256 swept = svault.sweepDust(IERC20(address(usdr)), recipient);

        assertEq(swept, stuck, "swept = vault balance");
        assertEq(usdr.balanceOf(recipient) - before_, stuck, "recipient credited");
        assertEq(usdr.balanceOf(address(svault)), 0, "vault drained");
    }

    function test_sweepDust_unauthorized_reverts() public {
        vm.prank(bob);
        vm.expectRevert();
        svault.sweepDust(IERC20(address(usdr)), bob);
    }

    function test_sweepDust_zeroBalance_returnsZero() public {
        // Vault has no USDr (no settlements run in this test).
        vm.prank(admin);
        uint256 swept = svault.sweepDust(IERC20(address(usdr)), admin);
        assertEq(swept, 0);
    }

    // ---- 2. forceEmergencySettlement bypasses the 60-day window -----

    function _triggerLiquidation() internal {
        vm.startPrank(bob);
        usdr.approve(address(pool), type(uint256).max);
        pool.deposit(2_000_000e18, bob);
        pool.approve(address(sp), 200_000e18);
        sp.deposit(200_000e18, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        pool.openVaultPosition();
        amfi.approve(address(adapter), 1_000_000e18);
        pool.depositAsset(address(adapter), abi.encode(uint256(1_000_000e18)));
        pool.borrow(address(adapter), ZERO_DATA, 700_000e18);
        vm.stopPrank();

        vm.prank(admin);
        oracle.setPrice(0.7e18); // crash 30%

        vm.prank(oldManager);
        proxy.liquidate(address(adapter), address(adapter), alice, ZERO_DATA, 0);
    }

    function test_forceEmergency_governanceCanBypass60Days() public {
        _triggerLiquidation();

        // Bob is the only agaSP holder besides RF — give him voting power
        // by rolling a block past the snapshot.
        vm.roll(block.number + 1);

        // Manager goes silent, but governance acts immediately.
        vm.prank(admin);
        svault.forceEmergencySettlement(1);

        // Bob and RF can now claim their pro-rata share of the seized RWA
        // *without* waiting 60 days.
        uint256 bobAmfiBefore = amfi.balanceOf(bob);
        svault.emergencyDistributeInKind(1, bob);
        assertGt(amfi.balanceOf(bob), bobAmfiBefore, "Bob received in-kind share");
    }

    function test_forceEmergency_unauthorized_reverts() public {
        _triggerLiquidation();
        vm.prank(bob);
        vm.expectRevert();
        svault.forceEmergencySettlement(1);
    }

    function test_forceEmergency_settledBatch_reverts() public {
        _triggerLiquidation();

        // Manager settles normally
        vm.startPrank(admin);
        usdr.mint(admin, 1_000_000e18);
        usdr.approve(address(svault), type(uint256).max);
        svault.grantManager(admin);
        svault.settleRedemption(1, 700_000e18);
        vm.stopPrank();

        // Now governance cannot force-emergency a settled batch
        vm.prank(admin);
        vm.expectRevert(AgamaSettlementVault.AlreadyResolved.selector);
        svault.forceEmergencySettlement(1);
    }

    function test_setStaleBatchPeriod_governanceOnly() public {
        // Governance can adjust the window without any demo-mode gate.
        vm.prank(admin);
        svault.setStaleBatchPeriod(30 days);
        assertEq(svault.staleBatchPeriod(), 30 days);

        vm.prank(bob);
        vm.expectRevert();
        svault.setStaleBatchPeriod(15 days);
    }
}

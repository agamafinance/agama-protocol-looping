// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DebtToken} from "src/core/DebtToken.sol";
import {ILendingPool} from "src/interfaces/ILendingPool.sol";

/// @dev Stub implementing only the views DebtToken reads.
contract MockPoolForDebt is ILendingPool {
    uint256 public idx = 1e27;

    function setIndex(uint256 i) external {
        idx = i;
    }

    function getNormalizedDebt() external view returns (uint256) {
        return idx;
    }

    function getNormalizedIncome() external view returns (uint256) {
        return idx;
    }

    function asset() external pure returns (address) {
        return address(0);
    }
}

contract DebtTokenTest is Test {
    DebtToken internal dt;
    MockPoolForDebt internal pool;

    address internal alice = address(0xA11CE);
    address internal eve = address(0xEEE);

    function setUp() public {
        pool = new MockPoolForDebt();
        dt = new DebtToken(address(pool), address(0xDEAD), "Agama Debt USDr", "agDEBT-USDr", 18);
    }

    function _mint(address user, uint256 amount) internal {
        uint256 idx = pool.idx();
        vm.prank(address(pool));
        dt.mint(user, amount, idx);
    }

    function _burn(address user, uint256 amount) internal {
        uint256 idx = pool.idx();
        vm.prank(address(pool));
        dt.burn(user, amount, idx);
    }

    // ---- Metadata ---------------------------------------------------------

    function test_metadata() public view {
        assertEq(dt.name(), "Agama Debt USDr");
        assertEq(dt.symbol(), "agDEBT-USDr");
        assertEq(dt.decimals(), 18);
    }

    // ---- Mint/burn at index 1.0 (no interest) -----------------------------

    function test_mint_atUnitIndex_balanceMatches() public {
        _mint(alice, 500e18);
        assertEq(dt.balanceOf(alice), 500e18);
        assertEq(dt.scaledBalanceOf(alice), 500e18);
        assertEq(dt.totalSupply(), 500e18);
    }

    function test_burn_partial() public {
        _mint(alice, 500e18);
        _burn(alice, 200e18);
        assertEq(dt.balanceOf(alice), 300e18);
    }

    function test_burn_capsAtUserBalance() public {
        _mint(alice, 100e18);
        _burn(alice, 1000e18);
        assertEq(dt.balanceOf(alice), 0);
        assertEq(dt.scaledBalanceOf(alice), 0);
    }

    // ---- Index growth → balanceOf increases, scaled stays ----------------

    function test_indexGrowth_increasesBalanceOf_scaledUntouched() public {
        _mint(alice, 1000e18);
        uint256 scaledBefore = dt.scaledBalanceOf(alice);

        // Index grows 10% (approx 10% interest accrued since mint)
        pool.setIndex(1.1e27);

        assertEq(dt.scaledBalanceOf(alice), scaledBefore, "scaled must not move");
        assertEq(dt.balanceOf(alice), 1100e18, "nominal grew with index");
        assertEq(dt.totalSupply(), 1100e18);
    }

    // ---- Mint at higher index → fewer scaled units --------------------------

    function test_mintAtHigherIndex_storesProportionalScaled() public {
        // Index = 1.0: mint 1000 → scaled 1000
        _mint(alice, 1000e18);
        assertEq(dt.scaledBalanceOf(alice), 1000e18);

        // Index now 2.0: minting another 1000 nominal → scaled adds 500
        pool.setIndex(2e27);
        _mint(alice, 1000e18);

        // scaled = 1000 (initial) + 500 = 1500
        assertEq(dt.scaledBalanceOf(alice), 1500e18);
        // balanceOf = 1500 × 2.0 = 3000
        assertEq(dt.balanceOf(alice), 3000e18);
    }

    // ---- Non-transferable contract ---------------------------------------

    function test_transfer_reverts() public {
        _mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(DebtToken.NonTransferable.selector);
        dt.transfer(eve, 1);
    }

    function test_transferFrom_reverts() public {
        _mint(alice, 100e18);
        vm.expectRevert(DebtToken.NonTransferable.selector);
        dt.transferFrom(alice, eve, 1);
    }

    function test_approve_reverts() public {
        vm.expectRevert(DebtToken.NonTransferable.selector);
        dt.approve(eve, 1);
    }

    function test_allowance_alwaysZero() public view {
        assertEq(dt.allowance(alice, eve), 0);
    }

    // ---- Access control ---------------------------------------------------

    function test_mint_onlyPool() public {
        vm.expectRevert(DebtToken.OnlyPool.selector);
        dt.mint(alice, 1, 1e27);
    }

    function test_burn_onlyPool() public {
        vm.expectRevert(DebtToken.OnlyPool.selector);
        dt.burn(alice, 1, 1e27);
    }

    function test_mint_zeroAmountReverts() public {
        vm.prank(address(pool));
        vm.expectRevert(DebtToken.AmountZero.selector);
        dt.mint(alice, 0, 1e27);
    }
}

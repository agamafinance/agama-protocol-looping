//! LendingPool — the core of the Agama Arbitrum money market (Aave-style).
//!
//! * Lenders deposit USDC and receive agUSD 1:1; staking agUSD into sagUSD earns the
//!   yield. Withdrawals burn agUSD for USDC while liquidity allows.
//! * Borrowers deposit RWA vault shares (Qiro / Tenka) as collateral and borrow USDC
//!   up to the per-vault LTV. Debt accrues with an index driven by an Aave-style
//!   kinked utilization curve; realized interest (net of the reserve factor) is minted
//!   as agUSD to the sagUSD contract, lifting its share price.
//! * Liquidation is permissionless: when a borrower's health factor drops below 1
//!   (a NavOracle `crash`), anyone repays up to 50% of the debt and seizes the
//!   collateral plus a bonus. The keeper races this tx through the Timeboost express
//!   lane.
//!
//! All internal accounting is WAD (1e18). USDC is scaled in/out at the edges.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#[macro_use]
extern crate alloc;
mod shared;

use alloc::vec::Vec;
use crate::shared::{
    borrow_rate, linear_interest, usdc_to_wad, wad, wad_div, wad_mul, wad_to_usdc, IERC20,
    INavOracle, IRwaVault,
};
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
    stylus_core::calls::Call,
};

sol! {
    event CollateralDeposited(address indexed user, address indexed vault, uint256 shares);
    event Borrowed(address indexed user, uint256 assets);
    event Liquidated(address indexed user, address indexed liquidator, address indexed vault, uint256 repaid, uint256 seizedShares);

    error NotOwner();
    error AlreadyInitialized();
    error VaultNotListed();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error HealthFactorTooLow();
    error TransferFailed();
    error NotLiquidatable();
    error ZeroAmount();
}

#[derive(SolidityError)]
pub enum PoolError {
    NotOwner(NotOwner),
    AlreadyInitialized(AlreadyInitialized),
    VaultNotListed(VaultNotListed),
    InsufficientLiquidity(InsufficientLiquidity),
    InsufficientCollateral(InsufficientCollateral),
    HealthFactorTooLow(HealthFactorTooLow),
    TransferFailed(TransferFailed),
    NotLiquidatable(NotLiquidatable),
    ZeroAmount(ZeroAmount),
}

sol_storage! {
    #[entrypoint]
    pub struct LendingPool {
        address owner;
        address usdc;
        address agusd;
        address sagusd;
        address oracle;
        address treasury;
        bool initialized;

        // interest model (WAD, per-year)
        uint256 base_rate;
        uint256 slope1;
        uint256 slope2;
        uint256 kink;
        uint256 reserve_factor;

        // debt index
        uint256 borrow_index;     // WAD, starts 1e18
        uint256 total_scaled;     // sum of user scaled debt (WAD)
        uint256 last_accrual;

        // collateral registry
        address[] vault_list;
        mapping(address => bool) vault_listed;
        mapping(address => uint256) vault_ltv;        // WAD
        mapping(address => uint256) vault_threshold;  // WAD
        mapping(address => uint256) vault_bonus;      // WAD (e.g. 0.10e18)
        mapping(address => uint256) vault_cap;        // shares cap (18dec)
        mapping(address => uint256) vault_total_shares;

        // positions
        mapping(address => uint256) user_scaled;                        // WAD scaled debt
        mapping(address => mapping(address => uint256)) user_collateral; // user => vault => shares
    }
}

const CLOSE_FACTOR: u128 = 500_000_000_000_000_000; // 0.5e18

#[public]
impl LendingPool {
    #[allow(clippy::too_many_arguments)]
    pub fn initialize(
        &mut self,
        usdc: Address,
        agusd: Address,
        sagusd: Address,
        oracle: Address,
        treasury: Address,
        base_rate: U256,
        slope1: U256,
        slope2: U256,
        kink: U256,
        reserve_factor: U256,
    ) -> Result<(), PoolError> {
        if self.initialized.get() {
            return Err(PoolError::AlreadyInitialized(AlreadyInitialized {}));
        }
        self.initialized.set(true);
        self.owner.set(self.vm().msg_sender());
        self.usdc.set(usdc);
        self.agusd.set(agusd);
        self.sagusd.set(sagusd);
        self.oracle.set(oracle);
        self.treasury.set(treasury);
        self.base_rate.set(base_rate);
        self.slope1.set(slope1);
        self.slope2.set(slope2);
        self.kink.set(kink);
        self.reserve_factor.set(reserve_factor);
        self.borrow_index.set(wad());
        self.last_accrual.set(U256::from(self.vm().block_timestamp()));
        Ok(())
    }

    pub fn list_vault(
        &mut self,
        vault: Address,
        ltv: U256,
        threshold: U256,
        bonus: U256,
        cap: U256,
    ) -> Result<(), PoolError> {
        self.only_owner()?;
        if !self.vault_listed.get(vault) {
            self.vault_listed.setter(vault).set(true);
            self.vault_list.push(vault);
        }
        self.vault_ltv.setter(vault).set(ltv);
        self.vault_threshold.setter(vault).set(threshold);
        self.vault_bonus.setter(vault).set(bonus);
        self.vault_cap.setter(vault).set(cap);
        Ok(())
    }

    // ---------------------------------------------------------------- lender side

    /// Deposit USDC, receive agUSD 1:1.
    pub fn lend(&mut self, assets: U256) -> Result<(), PoolError> {
        if assets.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        self.accrue();
        let user = self.vm().msg_sender();
        let me = self.vm().contract_address();
        self.pull_usdc(user, me, assets)?;
        // mint agUSD 1:1 (scale 6dec -> 18dec)
        let ag = IERC20::new(self.agusd.get());
        let amt = usdc_to_wad(assets);
        let cfg = Call::new_mutating(self);
        ag.mint(self.vm(), cfg, user, amt)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        Ok(())
    }

    /// Burn agUSD, receive USDC (liquidity permitting).
    pub fn withdraw(&mut self, assets: U256) -> Result<(), PoolError> {
        if assets.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        self.accrue();
        let user = self.vm().msg_sender();
        if self.cash() < assets {
            return Err(PoolError::InsufficientLiquidity(InsufficientLiquidity {}));
        }
        let ag = IERC20::new(self.agusd.get());
        let amt = usdc_to_wad(assets);
        let cfg = Call::new_mutating(self);
        ag.burn(self.vm(), cfg, user, amt)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        self.push_usdc(user, assets)?;
        Ok(())
    }

    // ------------------------------------------------------------- borrower side

    pub fn deposit_collateral(&mut self, vault: Address, shares: U256) -> Result<(), PoolError> {
        if !self.vault_listed.get(vault) {
            return Err(PoolError::VaultNotListed(VaultNotListed {}));
        }
        if shares.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        let user = self.vm().msg_sender();
        let me = self.vm().contract_address();
        let v = IERC20::new(vault);
        let cfg = Call::new_mutating(self);
        let ok = v
            .transfer_from(self.vm(), cfg, user, me, shares)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(PoolError::TransferFailed(TransferFailed {}));
        }
        let cur = self.user_collateral.getter(user).get(vault) + shares;
        self.user_collateral.setter(user).setter(vault).set(cur);
        let vt = self.vault_total_shares.get(vault) + shares;
        self.vault_total_shares.setter(vault).set(vt);
        self.vm().log(CollateralDeposited { user, vault, shares });
        Ok(())
    }

    pub fn withdraw_collateral(&mut self, vault: Address, shares: U256) -> Result<(), PoolError> {
        self.accrue();
        let user = self.vm().msg_sender();
        let cur = self.user_collateral.getter(user).get(vault);
        if cur < shares {
            return Err(PoolError::InsufficientCollateral(InsufficientCollateral {}));
        }
        self.user_collateral.setter(user).setter(vault).set(cur - shares);
        // must stay solvent against LTV
        if self.debt_wad(user) > self.borrow_power_wad(user) {
            return Err(PoolError::HealthFactorTooLow(HealthFactorTooLow {}));
        }
        let vt = self.vault_total_shares.get(vault) - shares;
        self.vault_total_shares.setter(vault).set(vt);
        let v = IERC20::new(vault);
        let cfg = Call::new_mutating(self);
        v.transfer(self.vm(), cfg, user, shares)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        Ok(())
    }

    pub fn borrow(&mut self, assets: U256) -> Result<(), PoolError> {
        if assets.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        self.accrue();
        let user = self.vm().msg_sender();
        if self.cash() < assets {
            return Err(PoolError::InsufficientLiquidity(InsufficientLiquidity {}));
        }
        let borrow_wad = usdc_to_wad(assets);
        let new_debt = self.debt_wad(user) + borrow_wad;
        if new_debt > self.borrow_power_wad(user) {
            return Err(PoolError::HealthFactorTooLow(HealthFactorTooLow {}));
        }
        let idx = self.borrow_index.get();
        let add_scaled = wad_div(borrow_wad, idx);
        let cur_scaled = self.user_scaled.get(user);
        self.user_scaled.setter(user).set(cur_scaled + add_scaled);
        self.total_scaled.set(self.total_scaled.get() + add_scaled);
        self.push_usdc(user, assets)?;
        self.vm().log(Borrowed { user, assets });
        Ok(())
    }

    pub fn repay(&mut self, assets: U256) -> Result<(), PoolError> {
        if assets.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        self.accrue();
        let user = self.vm().msg_sender();
        let me = self.vm().contract_address();
        let debt = self.debt_wad(user);
        let mut pay_wad = usdc_to_wad(assets);
        let mut pay_assets = assets;
        if pay_wad > debt {
            pay_wad = debt;
            pay_assets = wad_to_usdc(debt);
        }
        self.pull_usdc(user, me, pay_assets)?;
        let idx = self.borrow_index.get();
        let sub_scaled = wad_div(pay_wad, idx);
        let us = self.user_scaled.get(user);
        let us2 = if sub_scaled > us { U256::ZERO } else { us - sub_scaled };
        self.user_scaled.setter(user).set(us2);
        let ts = self.total_scaled.get();
        self.total_scaled.set(if sub_scaled > ts { U256::ZERO } else { ts - sub_scaled });
        Ok(())
    }

    /// Permissionless liquidation. Repay up to 50% of `user`'s debt in USDC and
    /// seize `vault` collateral worth the repay + liquidation bonus.
    pub fn liquidate(&mut self, user: Address, vault: Address, repay_assets: U256) -> Result<(), PoolError> {
        self.accrue();
        if self.health_factor(user) >= wad() {
            return Err(PoolError::NotLiquidatable(NotLiquidatable {}));
        }
        let debt = self.debt_wad(user);
        let max_repay = wad_mul(debt, U256::from(CLOSE_FACTOR));
        let mut repay_wad = usdc_to_wad(repay_assets);
        if repay_wad > max_repay {
            repay_wad = max_repay;
        }
        let repay_assets_capped = wad_to_usdc(repay_wad);
        if repay_assets_capped.is_zero() {
            return Err(PoolError::ZeroAmount(ZeroAmount {}));
        }
        let liquidator = self.vm().msg_sender();
        let me = self.vm().contract_address();
        self.pull_usdc(liquidator, me, repay_assets_capped)?;

        // reduce debt
        let idx = self.borrow_index.get();
        let sub_scaled = wad_div(repay_wad, idx);
        let us = self.user_scaled.get(user);
        let us2 = if sub_scaled > us { U256::ZERO } else { us - sub_scaled };
        self.user_scaled.setter(user).set(us2);
        let ts = self.total_scaled.get();
        self.total_scaled.set(if sub_scaled > ts { U256::ZERO } else { ts - sub_scaled });

        // seize collateral = repay * (1 + bonus) / nav
        let bonus = self.vault_bonus.get(vault);
        let seize_value = wad_mul(repay_wad, wad() + bonus);
        let nav = self.nav_of(vault);
        let mut seize_shares = wad_div(seize_value, nav);
        let have = self.user_collateral.getter(user).get(vault);
        if seize_shares > have {
            seize_shares = have;
        }
        self.user_collateral.setter(user).setter(vault).set(have - seize_shares);
        let vt = self.vault_total_shares.get(vault) - seize_shares;
        self.vault_total_shares.setter(vault).set(vt);
        let v = IERC20::new(vault);
        let cfg = Call::new_mutating(self);
        v.transfer(self.vm(), cfg, liquidator, seize_shares)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        self.vm().log(Liquidated {
            user,
            liquidator,
            vault,
            repaid: repay_assets_capped,
            seizedShares: seize_shares,
        });
        Ok(())
    }

    // ----------------------------------------------------------------- accrual

    /// Accrue interest into the borrow index and mint realized interest as agUSD
    /// to the sagUSD contract (net of the reserve factor). Anyone may call; it also
    /// runs at the top of every state-changing action.
    pub fn accrue(&mut self) {
        let now = self.vm().block_timestamp();
        let last = self.last_accrual.get().to::<u64>();
        if now <= last {
            return;
        }
        let dt = now - last;
        self.last_accrual.set(U256::from(now));
        let scaled = self.total_scaled.get();
        if scaled.is_zero() {
            return;
        }
        let idx = self.borrow_index.get();
        let old_borrows = wad_mul(scaled, idx);
        let util = self.utilization_inner(old_borrows);
        let rate = borrow_rate(
            util,
            self.base_rate.get(),
            self.slope1.get(),
            self.slope2.get(),
            self.kink.get(),
        );
        let growth = linear_interest(rate, dt); // WAD growth fraction
        let new_idx = idx + wad_mul(idx, growth);
        self.borrow_index.set(new_idx);
        let new_borrows = wad_mul(scaled, new_idx);
        let interest = new_borrows.saturating_sub(old_borrows);
        if interest.is_zero() {
            return;
        }
        let reserve = wad_mul(interest, self.reserve_factor.get());
        let to_stakers = interest - reserve;
        let ag = IERC20::new(self.agusd.get());
        let sagusd = self.sagusd.get();
        let treasury = self.treasury.get();
        if !to_stakers.is_zero() {
            let cfg = Call::new_mutating(self);
            let _ = ag.mint(self.vm(), cfg, sagusd, to_stakers);
        }
        if !reserve.is_zero() {
            let cfg = Call::new_mutating(self);
            let _ = ag.mint(self.vm(), cfg, treasury, reserve);
        }
    }

    // ------------------------------------------------------------------- views

    pub fn cash(&self) -> U256 {
        let usdc = IERC20::new(self.usdc.get());
        let me = self.vm().contract_address();
        usdc.balance_of(self.vm(), Call::new(), me).unwrap_or(U256::ZERO)
    }

    pub fn total_borrows(&self) -> U256 {
        wad_to_usdc(wad_mul(self.total_scaled.get(), self.borrow_index.get()))
    }

    pub fn utilization(&self) -> U256 {
        let borrows = wad_mul(self.total_scaled.get(), self.borrow_index.get());
        self.utilization_inner(borrows)
    }

    /// Supply rate (sagUSD APY) = util * borrowRate * (1 - reserveFactor). WAD/year.
    pub fn supply_rate_view(&self) -> U256 {
        let br = self.borrow_rate_view();
        let net = wad_mul(br, wad() - self.reserve_factor.get());
        wad_mul(self.utilization(), net)
    }

    /// Total collateral value of a user in USDC (6dec), un-weighted.
    pub fn collateral_value(&self, user: Address) -> U256 {
        wad_to_usdc(self.collateral_value_wad(user, false))
    }

    pub fn borrow_rate_view(&self) -> U256 {
        borrow_rate(
            self.utilization(),
            self.base_rate.get(),
            self.slope1.get(),
            self.slope2.get(),
            self.kink.get(),
        )
    }

    /// Debt of a user in USDC (6dec).
    pub fn debt_of(&self, user: Address) -> U256 {
        wad_to_usdc(self.debt_wad(user))
    }

    pub fn collateral_shares(&self, user: Address, vault: Address) -> U256 {
        self.user_collateral.getter(user).get(vault)
    }

    /// Health factor in WAD. >= 1e18 is safe; < 1e18 is liquidatable. Returns
    /// U256::MAX when the user has no debt.
    pub fn health_factor(&self, user: Address) -> U256 {
        let debt = self.debt_wad(user);
        if debt.is_zero() {
            return U256::MAX;
        }
        let weighted = self.collateral_value_wad(user, true);
        wad_div(weighted, debt)
    }

    pub fn vaults_count(&self) -> U256 {
        U256::from(self.vault_list.len())
    }
    pub fn vault_at(&self, i: U256) -> Address {
        self.vault_list.get(i.to::<usize>()).unwrap_or(Address::ZERO)
    }
}

impl LendingPool {
    fn only_owner(&self) -> Result<(), PoolError> {
        if self.vm().msg_sender() != self.owner.get() {
            return Err(PoolError::NotOwner(NotOwner {}));
        }
        Ok(())
    }

    fn utilization_inner(&self, borrows: U256) -> U256 {
        let cash = usdc_to_wad(self.cash());
        let total = cash + borrows;
        if total.is_zero() {
            return U256::ZERO;
        }
        wad_div(borrows, total)
    }

    fn debt_wad(&self, user: Address) -> U256 {
        wad_mul(self.user_scaled.get(user), self.borrow_index.get())
    }

    fn nav_of(&self, vault: Address) -> U256 {
        let oracle = INavOracle::new(self.oracle.get());
        oracle.nav_of(self.vm(), Call::new(), vault).unwrap_or(U256::ZERO)
    }

    /// Sum of collateral value across all listed vaults (WAD). If `weighted`, each
    /// vault's value is multiplied by its liquidation threshold (for HF); otherwise
    /// raw (for display).
    fn collateral_value_wad(&self, user: Address, weighted: bool) -> U256 {
        let n = self.vault_list.len();
        let mut total = U256::ZERO;
        for i in 0..n {
            let vault = self.vault_list.get(i).unwrap_or(Address::ZERO);
            let shares = self.user_collateral.getter(user).get(vault);
            if shares.is_zero() {
                continue;
            }
            let nav = self.nav_of(vault);
            let value = wad_mul(shares, nav);
            if weighted {
                total += wad_mul(value, self.vault_threshold.get(vault));
            } else {
                total += value;
            }
        }
        total
    }

    /// Max debt (WAD) a user can carry under per-vault LTV.
    fn borrow_power_wad(&self, user: Address) -> U256 {
        let n = self.vault_list.len();
        let mut total = U256::ZERO;
        for i in 0..n {
            let vault = self.vault_list.get(i).unwrap_or(Address::ZERO);
            let shares = self.user_collateral.getter(user).get(vault);
            if shares.is_zero() {
                continue;
            }
            let nav = self.nav_of(vault);
            let value = wad_mul(shares, nav);
            total += wad_mul(value, self.vault_ltv.get(vault));
        }
        total
    }

    fn pull_usdc(&mut self, from: Address, to: Address, assets: U256) -> Result<(), PoolError> {
        let usdc = IERC20::new(self.usdc.get());
        let cfg = Call::new_mutating(self);
        let ok = usdc
            .transfer_from(self.vm(), cfg, from, to, assets)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(PoolError::TransferFailed(TransferFailed {}));
        }
        Ok(())
    }

    fn push_usdc(&mut self, to: Address, assets: U256) -> Result<(), PoolError> {
        let usdc = IERC20::new(self.usdc.get());
        let cfg = Call::new_mutating(self);
        let ok = usdc
            .transfer(self.vm(), cfg, to, assets)
            .map_err(|_| PoolError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(PoolError::TransferFailed(TransferFailed {}));
        }
        Ok(())
    }
}

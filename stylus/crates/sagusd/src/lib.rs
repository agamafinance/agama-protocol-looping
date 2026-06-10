//! sagUSD — staked agUSD. ERC-4626-like, 18 decimals, **no lock**.
//!
//! Stake agUSD → sagUSD shares; unstake any time. The share price is
//! `totalAssets / totalSupply` where `totalAssets` is the agUSD this contract holds.
//! The LendingPool mints accrued borrower interest (net of the reserve factor) as
//! agUSD straight to this contract, which lifts the share price — so the sagUSD APY
//! is exactly the pool's utilization-curve yield. Idle agUSD earns nothing.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#[macro_use]
extern crate alloc;
mod shared;

use alloc::{string::String, vec::Vec};
use crate::shared::IERC20;
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
    stylus_core::calls::Call,
};

sol! {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Staked(address indexed user, uint256 assets, uint256 shares);
    event Unstaked(address indexed user, uint256 shares, uint256 assets);

    error InsufficientBalance();
    error AlreadyInitialized();
    error TransferFailed();
    error ZeroAmount();
}

#[derive(SolidityError)]
pub enum SagusdError {
    InsufficientBalance(InsufficientBalance),
    AlreadyInitialized(AlreadyInitialized),
    TransferFailed(TransferFailed),
    ZeroAmount(ZeroAmount),
}

sol_storage! {
    #[entrypoint]
    pub struct Sagusd {
        mapping(address => uint256) balances;
        uint256 total_supply;
        address agusd;
        bool initialized;
    }
}

#[public]
impl Sagusd {
    pub fn initialize(&mut self, agusd: Address) -> Result<(), SagusdError> {
        if self.initialized.get() {
            return Err(SagusdError::AlreadyInitialized(AlreadyInitialized {}));
        }
        self.initialized.set(true);
        self.agusd.set(agusd);
        Ok(())
    }

    pub fn name(&self) -> String {
        String::from("Staked Agama USD")
    }
    pub fn symbol(&self) -> String {
        String::from("sagUSD")
    }
    pub fn decimals(&self) -> u8 {
        18
    }
    pub fn asset(&self) -> Address {
        self.agusd.get()
    }
    pub fn total_supply(&self) -> U256 {
        self.total_supply.get()
    }
    pub fn balance_of(&self, who: Address) -> U256 {
        self.balances.get(who)
    }

    /// agUSD currently backing all sagUSD (this contract's agUSD balance).
    pub fn total_assets(&self) -> U256 {
        let token = IERC20::new(self.agusd.get());
        let me = self.vm().contract_address();
        token.balance_of(self.vm(), Call::new(), me).unwrap_or(U256::ZERO)
    }

    /// agUSD value of 1e18 sagUSD shares (WAD). Rises as interest accrues.
    pub fn price_per_share(&self) -> U256 {
        let supply = self.total_supply.get();
        if supply.is_zero() {
            return U256::from(1_000_000_000_000_000_000u128);
        }
        self.total_assets().saturating_mul(U256::from(1_000_000_000_000_000_000u128)) / supply
    }

    pub fn convert_to_shares(&self, assets: U256) -> U256 {
        let supply = self.total_supply.get();
        let ta = self.total_assets();
        if supply.is_zero() || ta.is_zero() {
            return assets;
        }
        assets.saturating_mul(supply) / ta
    }

    pub fn convert_to_assets(&self, shares: U256) -> U256 {
        let supply = self.total_supply.get();
        if supply.is_zero() {
            return shares;
        }
        shares.saturating_mul(self.total_assets()) / supply
    }

    /// Stake agUSD, receive sagUSD.
    pub fn stake(&mut self, assets: U256) -> Result<U256, SagusdError> {
        if assets.is_zero() {
            return Err(SagusdError::ZeroAmount(ZeroAmount {}));
        }
        let shares = self.convert_to_shares(assets);
        let user = self.vm().msg_sender();
        let me = self.vm().contract_address();
        let token = IERC20::new(self.agusd.get());
        let cfg = Call::new_mutating(self);
        let ok = token
            .transfer_from(self.vm(), cfg, user, me, assets)
            .map_err(|_| SagusdError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(SagusdError::TransferFailed(TransferFailed {}));
        }
        self._mint(user, shares);
        self.vm().log(Staked { user, assets, shares });
        Ok(shares)
    }

    /// Unstake: burn sagUSD, receive agUSD (principal + accrued yield).
    pub fn unstake(&mut self, shares: U256) -> Result<U256, SagusdError> {
        let user = self.vm().msg_sender();
        let bal = self.balances.get(user);
        if bal < shares {
            return Err(SagusdError::InsufficientBalance(InsufficientBalance {}));
        }
        let assets = self.convert_to_assets(shares);
        self._burn(user, shares);
        let token = IERC20::new(self.agusd.get());
        let cfg = Call::new_mutating(self);
        let ok = token
            .transfer(self.vm(), cfg, user, assets)
            .map_err(|_| SagusdError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(SagusdError::TransferFailed(TransferFailed {}));
        }
        self.vm().log(Unstaked { user, shares, assets });
        Ok(assets)
    }

    pub fn transfer(&mut self, to: Address, amount: U256) -> Result<bool, SagusdError> {
        let from = self.vm().msg_sender();
        let bal = self.balances.get(from);
        if bal < amount {
            return Err(SagusdError::InsufficientBalance(InsufficientBalance {}));
        }
        self.balances.setter(from).set(bal - amount);
        let tb = self.balances.get(to) + amount;
        self.balances.setter(to).set(tb);
        self.vm().log(Transfer { from, to, value: amount });
        Ok(true)
    }
}

impl Sagusd {
    fn _mint(&mut self, to: Address, amount: U256) {
        let b = self.balances.get(to) + amount;
        self.balances.setter(to).set(b);
        self.total_supply.set(self.total_supply.get() + amount);
        self.vm().log(Transfer { from: Address::ZERO, to, value: amount });
    }
    fn _burn(&mut self, from: Address, amount: U256) {
        let b = self.balances.get(from);
        self.balances.setter(from).set(b - amount);
        self.total_supply.set(self.total_supply.get() - amount);
        self.vm().log(Transfer { from, to: Address::ZERO, value: amount });
    }
}

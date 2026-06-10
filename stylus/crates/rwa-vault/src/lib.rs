//! RwaVault — a tokenized RWA credit-vault position (Qiro / Tenka).
//!
//! ERC-20 share token (18 decimals). Users deposit MockUSDC to mint shares at the
//! current NAV-per-share read live from the [NavOracle]; the share price rises as
//! the NAV accrues and *falls* when the oracle `crash`es (a credit event) — which is
//! exactly what pushes a borrower's health factor below 1. The LendingPool takes
//! custody of these shares as collateral via `transferFrom`.
//!
//! Deployed once per vault (6 instances). `symbol` is set at init so the same wasm
//! serves qPFV / qPCV / qICV / tSNR / tMEZ / tDV.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#[macro_use]
extern crate alloc;
mod shared;

use alloc::{string::String, vec::Vec};
use crate::shared::{usdc_to_wad, wad_div, wad_mul, wad_to_usdc, IERC20, INavOracle};
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
    stylus_core::calls::Call,
};

sol! {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 assets);

    error InsufficientBalance();
    error InsufficientAllowance();
    error AlreadyInitialized();
    error ZeroNav();
    error TransferFailed();
}

#[derive(SolidityError)]
pub enum VaultError {
    InsufficientBalance(InsufficientBalance),
    InsufficientAllowance(InsufficientAllowance),
    AlreadyInitialized(AlreadyInitialized),
    ZeroNav(ZeroNav),
    TransferFailed(TransferFailed),
}

sol_storage! {
    #[entrypoint]
    pub struct RwaVault {
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 total_supply;
        address asset_;        // MockUSDC
        address oracle;        // NavOracle
        string symbol_;
        bool initialized;
    }
}

#[public]
impl RwaVault {
    pub fn initialize(&mut self, asset: Address, oracle: Address, symbol: String) -> Result<(), VaultError> {
        if self.initialized.get() {
            return Err(VaultError::AlreadyInitialized(AlreadyInitialized {}));
        }
        self.initialized.set(true);
        self.asset_.set(asset);
        self.oracle.set(oracle);
        self.symbol_.set_str(symbol);
        Ok(())
    }

    pub fn name(&self) -> String {
        String::from("Agama RWA Vault Share")
    }
    pub fn symbol(&self) -> String {
        self.symbol_.get_string()
    }
    pub fn decimals(&self) -> u8 {
        18
    }
    pub fn asset(&self) -> Address {
        self.asset_.get()
    }
    pub fn total_supply(&self) -> U256 {
        self.total_supply.get()
    }
    pub fn balance_of(&self, who: Address) -> U256 {
        self.balances.get(who)
    }
    pub fn shares_of(&self, who: Address) -> U256 {
        self.balances.get(who)
    }
    pub fn allowance(&self, owner: Address, spender: Address) -> U256 {
        self.allowances.getter(owner).get(spender)
    }

    /// NAV-per-share in WAD (USDC value of 1 share, 1e18 == $1.00).
    pub fn nav_per_share(&self) -> U256 {
        let oracle = INavOracle::new(self.oracle.get());
        let me = self.vm().contract_address();
        oracle.nav_of(self.vm(), Call::new(), me).unwrap_or(U256::ZERO)
    }

    /// Deposit `assets` (USDC, 6dec) → mint shares at the current NAV.
    pub fn deposit(&mut self, assets: U256) -> Result<U256, VaultError> {
        let nav = self.nav_per_share();
        if nav.is_zero() {
            return Err(VaultError::ZeroNav(ZeroNav {}));
        }
        let user = self.vm().msg_sender();
        let me = self.vm().contract_address();
        // pull USDC
        let token = IERC20::new(self.asset_.get());
        let cfg = Call::new_mutating(self);
        let ok = token
            .transfer_from(self.vm(), cfg, user, me, assets)
            .map_err(|_| VaultError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(VaultError::TransferFailed(TransferFailed {}));
        }
        let shares = wad_div(usdc_to_wad(assets), nav);
        self._mint(user, shares);
        self.vm().log(Deposit { user, assets, shares });
        Ok(shares)
    }

    /// Redeem `shares` → USDC at the current NAV (if the vault holds enough USDC).
    pub fn redeem(&mut self, shares: U256) -> Result<U256, VaultError> {
        let nav = self.nav_per_share();
        let user = self.vm().msg_sender();
        let bal = self.balances.get(user);
        if bal < shares {
            return Err(VaultError::InsufficientBalance(InsufficientBalance {}));
        }
        let assets = wad_to_usdc(wad_mul(shares, nav));
        self._burn(user, shares);
        let token = IERC20::new(self.asset_.get());
        let cfg = Call::new_mutating(self);
        let ok = token
            .transfer(self.vm(), cfg, user, assets)
            .map_err(|_| VaultError::TransferFailed(TransferFailed {}))?;
        if !ok {
            return Err(VaultError::TransferFailed(TransferFailed {}));
        }
        self.vm().log(Redeem { user, shares, assets });
        Ok(assets)
    }

    pub fn approve(&mut self, spender: Address, amount: U256) -> bool {
        let owner = self.vm().msg_sender();
        self.allowances.setter(owner).insert(spender, amount);
        self.vm().log(Approval { owner, spender, value: amount });
        true
    }

    pub fn transfer(&mut self, to: Address, amount: U256) -> Result<bool, VaultError> {
        let from = self.vm().msg_sender();
        self._transfer(from, to, amount)?;
        Ok(true)
    }

    pub fn transfer_from(&mut self, from: Address, to: Address, amount: U256) -> Result<bool, VaultError> {
        let spender = self.vm().msg_sender();
        let cur = self.allowances.getter(from).get(spender);
        if cur < amount {
            return Err(VaultError::InsufficientAllowance(InsufficientAllowance {}));
        }
        if cur != U256::MAX {
            self.allowances.setter(from).insert(spender, cur - amount);
        }
        self._transfer(from, to, amount)?;
        Ok(true)
    }
}

impl RwaVault {
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
    fn _transfer(&mut self, from: Address, to: Address, amount: U256) -> Result<(), VaultError> {
        let bal = self.balances.get(from);
        if bal < amount {
            return Err(VaultError::InsufficientBalance(InsufficientBalance {}));
        }
        self.balances.setter(from).set(bal - amount);
        let to_bal = self.balances.get(to) + amount;
        self.balances.setter(to).set(to_bal);
        self.vm().log(Transfer { from, to, value: amount });
        Ok(())
    }
}
